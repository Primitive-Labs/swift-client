import XCTest
@testable import JsBaoClient

/// Phase D3 of the concurrency-modernization epic (#1993): `AnalyticsQueue`
/// becomes an `actor`, its buffer loses `Any`, and the synchronous public
/// surface on `JsBaoClient` / `AnalyticsAPI` is deprecated in favour of `Async`
/// twins (Fork 1 Option C).
///
/// Same two kinds of check as the D2 suite:
///
/// * **Structural** (comment-stripped source) — that the type really is an
///   actor with no lock left, that the epic has reached its three actors, that
///   the D2 bridge is gone, that `scheduleFlush()`'s decision region has no
///   `await` in it, that every deprecated member really has a twin, and that
///   the TSan baseline entry was actually removed.
/// * **Behavioral** — the round trips, the re-buffering, the overrides and the
///   two things the twins add over the deprecated members: `flushAsync()`
///   awaits transmission, and an awaited log is ordered against a later flush.
///
/// All server-free.
final class ActorizedAnalyticsQueueTests: XCTestCase {

    /// Records what a fake transport was handed, so a test can assert that a
    /// send really happened (and when).
    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        private var _completed = 0
        func record(_ message: String) { lock.withLock { _messages.append(message) } }
        func complete() { lock.withLock { _completed += 1 } }
        var messages: [String] { lock.withLock { _messages } }
        var completed: Int { lock.withLock { _completed } }
    }

    // MARK: - Behavior 2 — the actor, the lock, and the epic's actor count

    /// The phase's headline. An actor and a lock-guarded class behave
    /// identically from the outside, so this cannot be observed any other way.
    func testAnalyticsQueueIsDeclaredAsAnActor() throws {
        XCTAssertTrue(
            try Self.clientSource("Internal/AnalyticsQueue.swift").contains("public actor AnalyticsQueue"),
            "AnalyticsQueue must be an actor"
        )
    }

    /// The conversion has to *replace* the lock, not sit beside it. Behavior 2
    /// allows an explicitly enumerated, safety-argued snapshot holder; D3 needs
    /// none, so the budget is zero — for the lock and for the `Sendable`
    /// opt-out the lock justified.
    func testAnalyticsQueueDeclaresNoLock() throws {
        let source = try Self.code("Internal/AnalyticsQueue.swift")
        XCTAssertFalse(source.contains("NSLock("), "AnalyticsQueue must not declare a lock")
        XCTAssertFalse(source.contains("lock.withLock"), "AnalyticsQueue must not hold a lock")
        XCTAssertFalse(
            source.contains("class AnalyticsQueue"),
            "AnalyticsQueue must not still be a class"
        )
        XCTAssertFalse(
            source.contains("AnalyticsQueue: @unchecked Sendable"),
            "the @unchecked Sendable opt-out the lock justified must be gone"
        )
    }

    /// Behavior 2's count clause: `Sources/JsBaoClient` holds at least the
    /// three actors the trimmed scope names (`OfflineStore` and `KvCache` from
    /// D2, `AnalyticsQueue` from this phase), up from a baseline of zero.
    func testTheEpicHasReachedThreeActors() throws {
        let declared = try Self.allClientSources()
            .flatMap { source in
                Self.stripComments(source)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { $0.range(of: #"\bactor [A-Z]"#, options: .regularExpression) != nil }
            }
        XCTAssertGreaterThanOrEqual(
            declared.count, 3,
            "the trimmed Phase D scope converts three managers; found: \(declared)"
        )
        for expected in ["actor OfflineStore", "actor KvCache", "actor AnalyticsQueue"] {
            XCTAssertTrue(
                declared.contains { $0.contains(expected) },
                "missing `\(expected)` — found: \(declared)"
            )
        }
    }

    // MARK: - The #1985 invariant, structurally

    /// The check-and-schedule in `scheduleFlush()` used to be atomic because it
    /// held one lock. It is atomic now because it contains **no `await`** — a
    /// property actor isolation does *not* give you for free and the compiler
    /// does not check. Sliced on code anchors so a doc comment cannot decide it,
    /// and so the check fails loudly if the anchors move.
    func testScheduleFlushDecisionRegionContainsNoSuspensionPoint() throws {
        let source = try Self.code("Internal/AnalyticsQueue.swift")
        let region = try Self.slice(
            source,
            from: "guard flushTimer == nil else { return }",
            to: "onFlushScheduled?()"
        )
        XCTAssertFalse(region.isEmpty, "the decision region sliced empty — the anchors moved")
        XCTAssertFalse(
            region.contains("await"),
            """
            scheduleFlush()'s check-and-assign region must contain no suspension \
            point, or two concurrent logEvent()s can both see "no timer" and each \
            schedule one (#1985). Region:
            \(region)
            """
        )
    }

    // MARK: - The typed buffer, and the bridge that is gone

    /// D2 had to bridge the untyped buffer onto `OfflineStore`'s typed payload
    /// at the persist call site, and that bridge dropped a bad row silently.
    /// D3 removes the reason for it: the buffer is typed all the way through.
    func testTheD2AnalyticsBridgeIsGone() throws {
        let source = try Self.code("Internal/AnalyticsQueue.swift")
        XCTAssertFalse(source.contains("asJSONRows"), "the D2 persist bridge must be gone")
        XCTAssertFalse(source.contains("asAnyRows"), "the D2 restore bridge must be gone")
        XCTAssertFalse(
            source.contains("[[String: Any]]"),
            "the buffer and everything it feeds must be typed"
        )
        XCTAssertTrue(
            source.contains("var buffer: [[String: JSONValue]]"),
            "the buffer itself must carry the typed row"
        )
    }

    /// An untyped event still round-trips: the `Any` graph is lowered at the
    /// entry point and what lands in the buffer is the same data.
    func testUntypedEventRoundTripsThroughTheTypedBuffer() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "d3-test"))
        let prepared = try XCTUnwrap(queue.prepared([
            "action": "click",
            "feature": "cta",
            "count": 3,
            "ok": true,
            "context_json": ["marker": "typed", "nested": ["a": 1]],
        ]))
        await queue.logEvent(prepared)

        let buffered = await queue.bufferedEvents
        XCTAssertEqual(buffered.count, 1)
        let row = try XCTUnwrap(buffered.first)
        XCTAssertEqual(row["action"], .string("click"))
        XCTAssertEqual(row["feature"], .string("cta"))
        XCTAssertEqual(row["count"], .number(3))
        XCTAssertEqual(row["ok"], .bool(true))
        XCTAssertEqual(row["context_json"]?["nested"]?["a"], .number(1))
        XCTAssertNotNil(row["timestamp"]?.stringValue, "the queue stamps a timestamp")
        XCTAssertEqual(row["user_ulid"], .string(AnalyticsQueue.unauthenticatedUser))
    }

    /// A value that cannot be represented as JSON is dropped rather than
    /// poisoning the whole buffer — but it is *reported*. The D2 bridge dropped
    /// such a row silently, where the `JSONSerialization` call it replaced threw
    /// and was logged by the caller's `catch`.
    func testNonJSONRepresentableEventIsDroppedAndReported() async throws {
        struct NotJSON {}
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "d3-test"))
        XCTAssertNil(
            queue.prepared(["action": "click", "bad": NotJSON()]),
            "an event carrying a non-JSON value must not reach the buffer"
        )

        let source = try Self.code("Internal/AnalyticsQueue.swift")
        let region = try Self.slice(source, from: "func prepared(_ event: [String: Any])", to: "func prepared(_ event: AnalyticsEventInput)")
        XCTAssertTrue(
            region.contains("logger.warn"),
            "a dropped event must be logged, not lost silently"
        )

        // The queue still works after one is rejected.
        let good = try XCTUnwrap(queue.prepared(["action": "click"]))
        await queue.logEvent(good)
        let buffered = await queue.bufferedEvents
        XCTAssertEqual(buffered.count, 1)
    }

    /// The lowering has to survive the `NSNumber` bridging trap. A value that
    /// arrives from `JSONSerialization` — a cached HTTP body, a persisted
    /// graph — is an `NSNumber`, and `NSNumber(value: 1) as? Bool` **succeeds**,
    /// so a scalar fast path written with a bare `as?` reads the number `1`
    /// back as `true`. Both the analytics queue and `KvCache` go through this
    /// lowering, so the check covers both.
    func testBridgedNumbersAreNotMistakenForBooleans() throws {
        let graph = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"n":1,"z":0,"b":true,"f":false,"d":1.5}"#.utf8)
            ) as? [String: Any]
        )
        let row = try JSONValue.typedRow(from: graph)
        XCTAssertEqual(row["n"], .number(1), "a bridged 1 must stay a number, not become true")
        XCTAssertEqual(row["z"], .number(0), "a bridged 0 must stay a number, not become false")
        XCTAssertEqual(row["b"], .bool(true))
        XCTAssertEqual(row["f"], .bool(false))
        XCTAssertEqual(row["d"], .number(1.5))

        // And the native Swift side still round-trips.
        let native = try JSONValue.typedRow(from: ["n": 1, "b": true, "d": 1.5, "s": "x"])
        XCTAssertEqual(native["n"], .number(1))
        XCTAssertEqual(native["b"], .bool(true))
        XCTAssertEqual(native["d"], .number(1.5))
        XCTAssertEqual(native["s"], .string("x"))

        // Same lowering, reached through the cache's wrapper.
        XCTAssertEqual(try KvCache.cacheValue(from: graph)["n"], .number(1))
    }

    // MARK: - Flush: what the twin adds

    /// `flushAndWait()` returns only once the send has finished — the whole
    /// point of the twin. `flush()` returns while the send is still in flight,
    /// which is the shape the deprecated synchronous surface has.
    func testFlushAndWaitReturnsOnlyAfterTheSendCompletes() async throws {
        let recorder = SendRecorder()
        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "d3-test"),
            sendMessage: { message in
                try await Task.sleep(nanoseconds: 120_000_000)
                recorder.record(message)
                recorder.complete()
            },
            getConnectionId: { "conn-1" }
        )
        await queue.logEvent(AnalyticsEventInput(action: "click", feature: "cta"))

        await queue.flushAndWait()
        XCTAssertEqual(recorder.completed, 1, "flushAndWait must not return before the send completes")
        XCTAssertTrue(try XCTUnwrap(recorder.messages.first).contains("analytics.batch"))
        let drained = await queue.bufferedEvents
        XCTAssertTrue(drained.isEmpty, "a delivered batch leaves the buffer empty")
    }

    /// The fire-and-forget shape, for contrast: `flush()` hands the batch to an
    /// unstructured task and returns, so the send is still outstanding.
    /// `awaitPendingPersistence()` is how a caller joins it.
    func testFlushReturnsBeforeTheSendCompletesAndCanBeJoined() async throws {
        let recorder = SendRecorder()
        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "d3-test"),
            sendMessage: { _ in
                try await Task.sleep(nanoseconds: 150_000_000)
                recorder.complete()
            },
            getConnectionId: { "conn-1" }
        )
        await queue.logEvent(AnalyticsEventInput(action: "click"))

        await queue.flush()
        XCTAssertEqual(recorder.completed, 0, "flush() must not wait for the send")
        await queue.awaitPendingPersistence()
        XCTAssertEqual(recorder.completed, 1, "awaitPendingPersistence joins the in-flight send")
    }

    /// A failed send puts the events back and persists them, so a batch is
    /// never lost to a dropped socket.
    func testFailedSendReBuffersAndPersists() async throws {
        struct SendFailed: Error {}
        let provider = MemoryStorageProvider()
        let store = OfflineStore()
        await store.setStorageProvider(provider)

        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "d3-test"),
            appId: "app",
            offlineStore: store,
            sendMessage: { _ in throw SendFailed() },
            getConnectionId: { "conn-1" },
            getUserId: { "user" }
        )
        await queue.logEvent(AnalyticsEventInput(action: "click", feature: "cta"))
        await queue.flushAndWait()

        let buffered = await queue.bufferedEvents
        XCTAssertEqual(buffered.count, 1, "a failed send must re-buffer the batch")
        let persisted = try await store.loadAnalyticsQueue(appId: "app", userId: "user")
        XCTAssertEqual(persisted, buffered, "and persist it for the next launch")
    }

    /// With no connection there is nothing to send to, so the events stay put
    /// rather than being drained into nowhere.
    func testFlushWithoutAConnectionKeepsTheEventsBuffered() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "d3-test"))
        await queue.logEvent(AnalyticsEventInput(action: "click"))
        await queue.flushAndWait()
        let buffered = await queue.bufferedEvents
        XCTAssertEqual(buffered.count, 1, "no connection id means the batch is not drained")
    }

    /// `destroy()` cancels the timer and drains, waiting for the send —
    /// `JsBaoClient.destroy()` closes storage right after it returns.
    func testDestroyDrainsTheBufferAndWaits() async throws {
        let recorder = SendRecorder()
        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "d3-test"),
            sendMessage: { _ in
                try await Task.sleep(nanoseconds: 80_000_000)
                recorder.complete()
            },
            getConnectionId: { "conn-1" }
        )
        await queue.logEvent(AnalyticsEventInput(action: "click"))
        await queue.destroy()
        XCTAssertEqual(recorder.completed, 1, "destroy must not return with a send outstanding")
    }

    // MARK: - The typed entry point's field mapping (review of PR #2266)

    /// `asJSONObject()` is the only path the typed `logEvent` takes and it
    /// re-spells all 14 fields by hand. A copy-paste slip (`row["os_name"] =
    /// .string(os_version)`) or a dropped `if let` line would ship wrong or
    /// missing analytics dimensions on every event with the whole suite green,
    /// so every field is asserted key-by-key against a distinct value.
    func testAsJSONObjectMapsEveryFieldToItsOwnKey() throws {
        let input = AnalyticsEventInput(
            action: "action-value",
            feature: "feature-value",
            route: "route-value",
            plan: "plan-value",
            tenant_id: "tenant-value",
            user_ulid: "ulid-value",
            device_type: "device-value",
            os_name: "os-name-value",
            os_version: "os-version-value",
            browser_name: "browser-name-value",
            browser_version: "browser-version-value",
            app_version: "app-version-value",
            context_json: .object(["ctx": .string("ctx-value")]),
            user_created_at_epoch_s: 1_700_000_000
        )

        let row = input.asJSONObject()

        XCTAssertEqual(row["action"], .string("action-value"))
        XCTAssertEqual(row["feature"], .string("feature-value"))
        XCTAssertEqual(row["route"], .string("route-value"))
        XCTAssertEqual(row["plan"], .string("plan-value"))
        XCTAssertEqual(row["tenant_id"], .string("tenant-value"))
        XCTAssertEqual(row["user_ulid"], .string("ulid-value"))
        XCTAssertEqual(row["device_type"], .string("device-value"))
        XCTAssertEqual(row["os_name"], .string("os-name-value"))
        XCTAssertEqual(row["os_version"], .string("os-version-value"))
        XCTAssertEqual(row["browser_name"], .string("browser-name-value"))
        XCTAssertEqual(row["browser_version"], .string("browser-version-value"))
        XCTAssertEqual(row["app_version"], .string("app-version-value"))
        XCTAssertEqual(row["context_json"], .object(["ctx": .string("ctx-value")]))
        XCTAssertEqual(row["user_created_at_epoch_s"], .number(1_700_000_000))
        XCTAssertEqual(row.count, 14, "no extra keys, and none of the 14 collapsed onto another")
    }

    /// The other half of the mapping's contract: a nil field is *dropped*, not
    /// written as `.null` — the queue's defaulting and override logic keys off
    /// the key being absent.
    func testAsJSONObjectDropsNilFieldsRatherThanNullingThem() throws {
        let row = AnalyticsEventInput(action: "click").asJSONObject()
        XCTAssertEqual(row, ["action": .string("click")],
                       "only the one non-nil field may appear")
    }

    /// The same 14 fields on the untyped bridge, so the two spellings cannot
    /// drift apart. `asDictionary()` is what the deprecated `[String: Any]`
    /// callers still reach.
    func testAsDictionaryCarriesTheSameKeysAsAsJSONObject() throws {
        let input = AnalyticsEventInput(
            action: "a", feature: "b", route: "c", plan: "d", tenant_id: "e",
            user_ulid: "f", device_type: "g", os_name: "h", os_version: "i",
            browser_name: "j", browser_version: "k", app_version: "l",
            context_json: .object(["m": .string("n")]), user_created_at_epoch_s: 7
        )
        XCTAssertEqual(
            Set(input.asDictionary().keys), Set(input.asJSONObject().keys),
            "the typed and untyped bridges must spell the same fields"
        )
    }

    // MARK: - Overrides and trimming survive the conversion

    /// An awaited override applies to every subsequent awaited event — the
    /// ordering the `Async` twins buy over the deprecated members.
    func testOverridesApplyToSubsequentEvents() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "d3-test"))
        await queue.setPlanOverride("pro")
        await queue.setAppVersionOverride("9.9.9")
        await queue.logEvent(AnalyticsEventInput(action: "click", plan: "free"))

        let buffered = await queue.bufferedEvents
        let row = try XCTUnwrap(buffered.first)
        XCTAssertEqual(row["plan"], .string("pro"), "the override wins over the event's own field")
        XCTAssertEqual(row["app_version"], .string("9.9.9"))
    }

    /// An oversized `context_json` is dropped rather than shipped, exactly as
    /// the lock version did (the size check moved from `JSONSerialization` to
    /// the typed encoder, not away).
    func testOversizedContextIsTrimmed() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "d3-test"))
        let big = String(repeating: "x", count: 4096)
        await queue.logEvent(AnalyticsEventInput(
            action: "big", context_json: .object(["payload": .string(big)])
        ))
        let small = await queue.bufferedEvents
        XCTAssertNil(small.first?["context_json"], "an oversized context must be dropped")

        await queue.logEvent(AnalyticsEventInput(
            action: "small", context_json: .object(["payload": .string("ok")])
        ))
        let rows = await queue.bufferedEvents
        XCTAssertNotNil(rows.last?["context_json"], "a small context must survive")
    }

    // MARK: - Fork 1 Option C: every deprecated member has a twin

    /// The policy of record is "additive `async` twins + one-release
    /// deprecation". This asserts both halves for all nine members, so a future
    /// edit cannot quietly drop a twin or un-deprecate an original.
    func testEveryDeprecatedAnalyticsMemberHasAnAsyncTwin() throws {
        let pairs: [(file: String, sync: String, twin: String)] = [
            ("JsBaoClient.swift", "func logAnalyticsEvent(", "func logAnalyticsEventAsync("),
            ("JsBaoClient.swift", "func flushAnalytics(", "func flushAnalyticsAsync("),
            ("JsBaoClient.swift", "func setAnalyticsPlanOverride(", "func setAnalyticsPlanOverrideAsync("),
            ("JsBaoClient.swift", "func setAnalyticsAppVersionOverride(", "func setAnalyticsAppVersionOverrideAsync("),
            ("API/AnalyticsAPI.swift", "func logEvent(", "func logEventAsync("),
            ("API/AnalyticsAPI.swift", "func logSnapshot(", "func logSnapshotAsync("),
            ("API/AnalyticsAPI.swift", "func flush(", "func flushAsync("),
            ("API/AnalyticsAPI.swift", "func setPlanOverride(", "func setPlanOverrideAsync("),
            ("API/AnalyticsAPI.swift", "func setAppVersionOverride(", "func setAppVersionOverrideAsync("),
        ]
        for pair in pairs {
            let source = try Self.clientSource(pair.file)
            XCTAssertTrue(
                source.contains(pair.twin),
                "\(pair.file): missing the async twin `\(pair.twin)`"
            )
            // The original survives the deprecation window, and is marked.
            let declaration = try XCTUnwrap(
                source.range(of: "public \(pair.sync)"),
                "\(pair.file): the synchronous `\(pair.sync)` must survive the deprecation window"
            )
            let preceding = String(source[source.startIndex..<declaration.lowerBound].suffix(1200))
            XCTAssertTrue(
                preceding.contains("@available(*, deprecated"),
                "\(pair.file): `\(pair.sync)` must be marked deprecated"
            )
        }
    }

    /// The twins are deliberately *not* same-name `async` overloads: Swift
    /// prefers the `async` overload in an asynchronous context, so a same-name
    /// twin makes every existing un-`await`ed call a compile error — the source
    /// break the window exists to avoid. Pin the reasoning next to the code.
    func testTheTwinNamingRationaleIsRecorded() throws {
        let source = try Self.clientSource("API/AnalyticsAPI.swift")
        XCTAssertTrue(
            source.contains("prefers an `async` overload"),
            "the reason the twins carry a distinct name must stay written down"
        )
    }

    // MARK: - Behavior 8 — the TSan baseline shrank

    /// The `AnalyticsQueue` / `flushTimer` entries were type-level, so they
    /// masked *any* race in the file. They come out with the conversion, and the
    /// suite that exercises the race is in the gate's default filter so the
    /// removal is actually tested.
    func testTsanBaselineNoLongerExemptsAnalyticsQueue() throws {
        let script = try Self.repoFile("swift-client/scripts/tsan-gate.sh")
        let signatures = try Self.slice(script, from: "BASELINE_RACE_SIGNATURES=(", to: "\n)")
        XCTAssertFalse(
            signatures.contains("'AnalyticsQueue'"),
            "the AnalyticsQueue baseline entry must be gone once the type is an actor"
        )
        XCTAssertFalse(
            signatures.contains("'flushTimer'"),
            "the flushTimer baseline entry must be gone with it"
        )
        XCTAssertTrue(
            script.contains("AnalyticsQueueFlushTimerRaceTests"),
            "the gate must run the suite whose race the removed entries covered"
        )
    }

    // MARK: - Behavior 13 — the hot path did not regress

    /// A 10,000-call loop through the untyped entry point's caller-side work.
    /// The plan's budget is 2× the pre-conversion wall time; the pre-conversion
    /// measurement on the development machine was 4.9 ms for this loop, so the
    /// assertion here is deliberately loose (10×) — it exists to catch a
    /// *catastrophic* regression on unknown CI hardware, not to police a few
    /// hundred microseconds. The real number is recorded in the PR.
    ///
    /// What it measures is `prepared()`, which is `nonisolated`: the `Any` →
    /// `JSONValue` lowering that runs on the caller's thread before the actor
    /// hop. That is the part the conversion made more expensive and the part a
    /// per-event `JSONSerialization` round trip would show up in. It is
    /// deliberately *not* the actor hop or the buffering — those are one
    /// `await` per call and cannot be timed without the rate limiter and the
    /// executor in the measurement (review of PR #2266).
    ///
    /// Skipped under ThreadSanitizer. The suite is in `tsan-gate.sh`'s default
    /// filter for its `flush` / `takeBatch` / `deliver` / `persistBuffer` /
    /// `destroy` coverage, but TSan costs ~4× on this loop (measured: 0.011 s
    /// plain vs 0.044 s sanitized), which spends most of the 10× margin the
    /// budget reserves for unknown CI hardware. A wall-clock assertion is not
    /// what the sanitized run is there to check (review of PR #2266).
    func testUntypedLoggingHotPathDoesNotRegress() throws {
        try XCTSkipIf(
            Self.threadSanitizerActive,
            "wall-clock budget is not meaningful under ThreadSanitizer (~4× overhead)"
        )
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "d3-perf"))
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<10_000 {
            _ = queue.prepared(["action": "bench", "feature": "perf", "i": i])
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(
            elapsedMs, 50,
            "10,000 untyped analytics events took \(elapsedMs) ms — the conversion regressed the hot path"
        )
    }

    /// The conversion must not have put a `JSONSerialization` round trip on the
    /// per-event path. This is the structural half of the check above, and the
    /// one that will not flake on a loaded machine.
    func testTheUntypedEntryPointDoesNotSerializePerEvent() throws {
        let source = try Self.code("Internal/AnalyticsQueue.swift")
        XCTAssertFalse(
            source.contains("JSONSerialization"),
            "the queue must not reach for JSONSerialization — JSONValue lowering is structural"
        )
    }

    // MARK: - Helpers

    // The implementations live in `Helpers/ClientSourceText.swift` — every
    // phase of the concurrency epic needs the same handful, so there is one
    // copy (consolidated in Phase D4). These are the local names the tests
    // above use.

    private static func code(_ relativePath: String) throws -> String {
        try ClientSourceText.code(relativePath)
    }

    /// True when this process is running under ThreadSanitizer.
    ///
    /// `tsan-gate.sh` exports `TSAN_OPTIONS` before every `swift test
    /// --sanitize thread` it runs, so the variable's presence is the marker
    /// for "this is the sanitized run" (the gate is the only sanctioned way
    /// to run the suite under TSan). Nothing else in the suite reads it, and
    /// the only consequence of a false positive is one skipped timer.
    private static var threadSanitizerActive: Bool {
        ProcessInfo.processInfo.environment["TSAN_OPTIONS"] != nil
    }

    static func stripComments(_ source: String) -> String {
        ClientSourceText.stripComments(source)
    }

    private static func clientSource(_ relativePath: String) throws -> String {
        try ClientSourceText.clientSource(relativePath)
    }

    private static func repoFile(_ relativePath: String) throws -> String {
        try ClientSourceText.repoFile(relativePath)
    }

    private static func allClientSources() throws -> [String] {
        try ClientSourceText.allClientSources()
    }

    private static func slice(_ source: String, from: String, to: String) throws -> String {
        try ClientSourceText.slice(source, from: from, to: to)
    }
}
