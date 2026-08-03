import Foundation

/// Batches and sends analytics events, with rate limiting and persistence.
///
/// An `actor` since #1993 Phase D3. What used to be one `NSLock` around six
/// pieces of mutable state is actor isolation; the `@unchecked Sendable`
/// opt-out and every `lock.withLock` are gone. Two consequences worth stating
/// because they are not obvious from the type:
///
/// * **The buffer is typed.** `Any` cannot cross an isolation boundary, so the
///   buffer holds `[String: JSONValue]` rows — the same shape `OfflineStore`
///   has taken since Phase D2. The bridge D2 put at the persist call site
///   (`asJSONRows` / `asAnyRows`, which dropped a bad row silently) is gone;
///   the one remaining conversion is at the untyped entry point below, and it
///   logs what it drops.
/// * **Everything here is async.** The synchronous public surface that has to
///   survive the deprecation window lives on `JsBaoClient` and `AnalyticsAPI`,
///   which stay classes — see the Fork 1 Option C note on those types.
public actor AnalyticsQueue {
    public static let unauthenticatedUser = "UNAUTHENTICATED"

    /// Shared formatter — `ISO8601DateFormatter` is expensive to construct,
    /// so we reuse one instance instead of allocating per event. The class
    /// is documented as thread-safe for `string(from:)` calls, so the
    /// immutable shared instance is safe to read concurrently even though
    /// `ISO8601DateFormatter` is not `Sendable` — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    /// Immutable and `Sendable`, so the `nonisolated` entry points below can
    /// report a dropped event without hopping onto the actor first.
    private nonisolated let logger: Logger

    // Buffer
    private var buffer: [[String: JSONValue]] = []
    private var flushTimer: Task<Void, Never>?
    private var rateCounter = 0
    private var rateWindowStart: Date = Date()

    // In-flight flush task (send + persist-on-failure). Tracked so
    // destroy() can await any final flush before the storage layer
    // closes — see AuthController.pendingPersistTask for the same
    // pattern's motivation.
    private var pendingFlushTask: Task<Void, Never>?

    // Overrides
    private var planOverride: String?
    private var appVersionOverride: String?

    // Config
    private static let flushIntervalMs: Int = 100
    private static let rateLimit: Int = 300
    private static let burstCap: Int = 60
    private static let maxPersistedBytes: Int = 1024 * 1024
    private static let contextBlobLimit: Int = 1024

    // Dependencies. Supplied at construction rather than assigned afterwards:
    // an actor has no synchronous setter, and `JsBaoClient` builds the queue
    // in its own `init` where the collaborators are already in hand (the same
    // ordering fix Phase D2 made for `KvCache`'s emitter).
    private let sendMessage: (@Sendable (String) async throws -> Void)?
    private let getConnectionId: (@Sendable () -> String?)?
    private let getUserId: (@Sendable () -> String?)?
    private let offlineStore: OfflineStore?
    private let appId: String

    /// Test-observability hook: invoked with the fully-prepared event right
    /// before it is buffered. Internal (visible only via `@testable import`)
    /// — the live-integration analytics tests use it to observe auto-events
    /// (#963) the same way the JS tests observe `client.analyticsQueue`.
    /// Never set in production code.
    private var onEventLogged: (@Sendable ([String: JSONValue]) -> Void)?

    /// Test-observability hook: invoked once each time `scheduleFlush()`
    /// actually creates a new flush timer (not on calls that find one
    /// already scheduled). Internal (visible only via `@testable import`)
    /// — the #1985 concurrency test uses it to assert that a burst of
    /// concurrent `logEvent`s schedules exactly one timer. Never set in
    /// production code.
    private var onFlushScheduled: (@Sendable () -> Void)?

    public init(
        logger: Logger,
        appId: String = "",
        offlineStore: OfflineStore? = nil,
        sendMessage: (@Sendable (String) async throws -> Void)? = nil,
        getConnectionId: (@Sendable () -> String?)? = nil,
        getUserId: (@Sendable () -> String?)? = nil
    ) {
        self.logger = logger.forScope(scope: "analytics")
        self.appId = appId
        self.offlineStore = offlineStore
        self.sendMessage = sendMessage
        self.getConnectionId = getConnectionId
        self.getUserId = getUserId
    }

    // MARK: - Test hooks

    func setOnEventLogged(_ hook: (@Sendable ([String: JSONValue]) -> Void)?) {
        onEventLogged = hook
    }

    func setOnFlushScheduled(_ hook: (@Sendable () -> Void)?) {
        onFlushScheduled = hook
    }

    /// The buffered rows, for tests that need to assert what a restore or a
    /// failed send actually put back.
    var bufferedEvents: [[String: JSONValue]] { buffer }

    // MARK: - Overrides

    /// Override the plan field on all subsequent analytics events.
    public func setPlanOverride(_ plan: String?) {
        planOverride = plan
    }

    /// Override the app version field on all subsequent analytics events.
    public func setAppVersionOverride(_ version: String?) {
        appVersionOverride = version
    }

    // MARK: - Preparing an event off the actor

    /// An event that has been lowered into the buffer's row shape but not yet
    /// buffered, carrying the instant it was logged.
    ///
    /// The instant travels as a `Date` rather than a formatted string because
    /// `ISO8601DateFormatter` is the single most expensive step per event, and
    /// a rate-limited event never needs it — the queue formats after it has
    /// decided to keep the event. Carrying it at all is what lets a caller on
    /// the deprecated synchronous surface get the time it *logged* the event
    /// rather than the time the enqueue task happened to run.
    public struct PreparedEvent: Sendable {
        var row: [String: JSONValue]
        var occurredAt: Date
    }

    /// Lower a caller's untyped event into the buffer's row shape **on the
    /// calling thread** — the untyped shape cannot cross the actor boundary, so
    /// this is where an `Any` graph stops.
    ///
    /// Returns `nil` for an event that is not JSON-representable. Such an event
    /// is dropped, but never silently: the drop is logged here, which is the
    /// visibility the Phase D2 bridge lost when it replaced a throwing
    /// `JSONSerialization` call with a `compactMap`.
    public nonisolated func prepared(_ event: [String: Any]) -> PreparedEvent? {
        do {
            let row = try JSONValue.typedRow(from: event, subject: "Analytics event fields")
            return PreparedEvent(row: row, occurredAt: Date())
        } catch {
            logger.warn("Dropping a non-JSON-representable analytics event:", error.localizedDescription)
            return nil
        }
    }

    /// The typed twin of `prepared(_:)` — nothing can fail here, and no
    /// conversion is needed: `AnalyticsEventInput` builds the row directly.
    public nonisolated func prepared(_ event: AnalyticsEventInput) -> PreparedEvent {
        PreparedEvent(row: event.asJSONObject(), occurredAt: Date())
    }

    // MARK: - Event Logging

    /// Typed entry point used by `client.analytics.logEvent(_:)`. Funnels
    /// through the same defaulting / override / rate-limit logic as every
    /// other entry point.
    public func logEvent(_ event: AnalyticsEventInput) {
        ingest(event.asJSONObject(), occurredAt: Date())
    }

    /// Entry point for a row prepared off the actor (see `prepared(_:)`).
    public func logEvent(_ event: PreparedEvent) {
        ingest(event.row, occurredAt: event.occurredAt)
    }

    /// Entry point for callers that build the typed shape themselves.
    public func logEvent(_ event: [String: JSONValue]) {
        ingest(event, occurredAt: Date())
    }

    private func ingest(_ event: [String: JSONValue], occurredAt: Date) {
        guard isWithinRateLimit() else {
            logger.debug("Analytics rate limit exceeded, dropping event")
            return
        }

        var preparedEvent = event
        if preparedEvent["user_ulid"] == nil {
            preparedEvent["user_ulid"] = .string(getUserId?() ?? Self.unauthenticatedUser)
        }
        preparedEvent["timestamp"] = .string(Self.timestampFormatter.string(from: occurredAt))

        // Apply overrides
        if let plan = planOverride { preparedEvent["plan"] = .string(plan) }
        if let version = appVersionOverride { preparedEvent["app_version"] = .string(version) }

        // Trim context_json if too large
        if let context = preparedEvent["context_json"], context.objectValue != nil,
           let data = try? JSONCoding.encodeData(context), data.count > Self.contextBlobLimit {
            preparedEvent["context_json"] = nil
        }

        buffer.append(preparedEvent)

        onEventLogged?(preparedEvent)

        scheduleFlush()
    }

    // MARK: - Flush

    /// Drain the buffer and hand the batch to the transport **without waiting
    /// for the send**. This is the shape the queue has always had — the send
    /// has always run in an unstructured `Task`.
    public func flush() {
        guard let batch = takeBatch() else { return }
        pendingFlushTask = Task { await self.deliver(batch) }
    }

    /// Drain the buffer and wait until the batch has actually reached the
    /// socket — or, on a send failure, until the events are re-buffered and
    /// persisted.
    ///
    /// This is the behavior the deprecated synchronous `flush()` could never
    /// offer: that one returns as soon as the send is *scheduled*, so a caller
    /// that flushes and then tears the client down can lose the batch.
    public func flushAndWait() async {
        guard let batch = takeBatch() else { return }
        let task = Task { await self.deliver(batch) }
        pendingFlushTask = task
        await task.value
    }

    /// Take the whole buffer and encode it as one `analytics.batch` frame.
    ///
    /// Returns `nil` — leaving the events buffered — when there is nothing to
    /// send, when there is no connection to send it on, or when the frame
    /// cannot be encoded. The buffer is only emptied for a batch that is
    /// actually handed on.
    private func takeBatch() -> (message: String, events: [[String: JSONValue]])? {
        let events = buffer
        buffer.removeAll()
        guard !events.isEmpty else { return nil }

        guard let connectionId = getConnectionId?() else {
            // Re-buffer for later
            buffer.insert(contentsOf: events, at: 0)
            return nil
        }

        let message: [String: JSONValue] = [
            "type": .string("analytics.batch"),
            "connection_id": .string(connectionId),
            "events": .array(events.map { .object($0) }),
        ]

        guard let jsonData = try? JSONCoding.encodeData(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            // Not reachable for a `JSONValue` graph, but re-buffer rather than
            // drop: the pre-D3 code returned here and lost the batch.
            buffer.insert(contentsOf: events, at: 0)
            logger.warn("Failed to encode an analytics batch; keeping the events buffered")
            return nil
        }

        return (jsonString, events)
    }

    private func deliver(_ batch: (message: String, events: [[String: JSONValue]])) async {
        do {
            try await sendMessage?(batch.message)
        } catch {
            // Persist failed events
            buffer.insert(contentsOf: batch.events, at: 0)
            await persistBuffer()
        }
    }

    /// Wait for any in-flight flush task to drain. Called from
    /// `JsBaoClient.destroy()` after `destroy()` cancels the periodic
    /// flush timer and triggers the final flush — without awaiting,
    /// the persist-on-failure path could race the SQLite close.
    public func awaitPendingPersistence() async {
        await pendingFlushTask?.value
    }

    // MARK: - Persistence

    public func persistBuffer() async {
        // Enforce the persisted-bytes cap (oldest-event eviction) before
        // reading the buffer to persist, mirroring the JS client's
        // `enforcePersistenceCap()` which trims the buffer in place ahead
        // of every persist (analyticsQueue.ts).
        enforcePersistenceCap()

        let events = buffer

        guard !events.isEmpty, let userId = getUserId?() else { return }

        do {
            try await offlineStore?.persistAnalyticsQueue(appId: appId, userId: userId, events: events)
        } catch {
            logger.warn("Failed to persist analytics queue:", error.localizedDescription)
        }
    }

    /// Trim the oldest buffered events until the serialized buffer fits
    /// within `maxPersistedBytes` (1 MiB), matching the JS client's FIFO
    /// `enforcePersistenceCap()`. Byte count is the UTF-8 length of the
    /// JSON-serialized buffer — the same payload the OfflineStore persists.
    private func enforcePersistenceCap() {
        var totalBytes = estimatedBufferBytes(buffer)
        if totalBytes <= Self.maxPersistedBytes { return }

        logger.warn(
            "Offline analytics queue exceeded capacity; truncating oldest events",
            "totalBytes=\(totalBytes) limit=\(Self.maxPersistedBytes)"
        )

        while !buffer.isEmpty && totalBytes > Self.maxPersistedBytes {
            buffer.removeFirst()
            totalBytes = estimatedBufferBytes(buffer)
        }
    }

    /// UTF-8 byte length of the JSON-serialized events, matching JS's
    /// `estimatedBufferBytes` (`utf8ByteLength(JSON.stringify(events))`).
    /// Returns 0 for an empty buffer.
    private func estimatedBufferBytes(_ events: [[String: JSONValue]]) -> Int {
        if events.isEmpty { return 0 }
        guard let data = try? JSONCoding.encodeData(events.map { JSONValue.object($0) }) else { return 0 }
        return data.count
    }

    public func restoreBuffer() async {
        guard let userId = getUserId?() else { return }

        do {
            let events = try await offlineStore?.loadAnalyticsQueue(appId: appId, userId: userId) ?? []
            if !events.isEmpty {
                buffer.insert(contentsOf: events, at: 0)
                scheduleFlush()
            }
        } catch {
            logger.warn("Failed to restore analytics queue:", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    /// Cancel the periodic flush timer and drain whatever is buffered, waiting
    /// for the send. `JsBaoClient.destroy()` closes the storage layer right
    /// after, so this must not return while a persist-on-failure write is
    /// still outstanding.
    public func destroy() async {
        flushTimer?.cancel()
        flushTimer = nil
        await flushAndWait()
    }

    deinit {
        // Final safety net: if the owning client was destroyed without
        // calling destroy() (and therefore without flushing), we still cancel
        // the timer here. We can't await in a deinit, so we cannot call the
        // async persistBuffer() — callers should call destroy() explicitly
        // before letting the queue go out of scope to guarantee persistence.
        flushTimer?.cancel()
    }

    // MARK: - Private

    private func scheduleFlush() {
        // Check-and-schedule must be atomic: the `flushTimer != nil` check and
        // the assignment must not be separated, or two concurrent `logEvent`s
        // could both see "no timer" and each schedule one (issue #1985). Under
        // the lock that was one `withLock` hold; under actor isolation it is
        // this region containing **no `await`** — a property the compiler does
        // not check for you, so `AnalyticsQueueFlushTimerRaceTests` asserts the
        // behavior and the D3 structural test asserts the region. Creating the
        // Task does not run its body, so it introduces no suspension; the
        // timer's own body (sleep, then flush) runs later.
        guard flushTimer == nil else { return }
        flushTimer = makeFlushTimer()
        onFlushScheduled?()
    }

    /// The timer's body lives here, not inline in `scheduleFlush()`, so the
    /// decision region above stays free of the word `await` — the structural
    /// test slices it on those two anchors, and an `await` inside a closure
    /// that does not run yet would read the same as a real suspension point.
    private func makeFlushTimer() -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushIntervalMs) * 1_000_000)
            await self?.flushTimerFired()
        }
    }

    /// The timer's body, back on the actor: clear the timer slot first so a
    /// `logEvent` arriving during the flush schedules the next one.
    private func flushTimerFired() {
        flushTimer = nil
        flush()
    }

    private func isWithinRateLimit() -> Bool {
        let now = Date()
        let windowElapsed = now.timeIntervalSince(rateWindowStart)

        if windowElapsed >= 60 {
            rateCounter = 0
            rateWindowStart = now
        }

        if rateCounter >= Self.rateLimit {
            return false
        }

        // Burst check
        if rateCounter >= Self.burstCap && windowElapsed < 10 {
            return false
        }

        rateCounter += 1
        return true
    }
}
