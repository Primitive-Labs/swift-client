import Foundation

/// Batches and sends analytics events, with rate limiting and persistence.
public final class AnalyticsQueue: @unchecked Sendable {
    public static let unauthenticatedUser = "UNAUTHENTICATED"

    /// Shared formatter — `ISO8601DateFormatter` is expensive to construct,
    /// so we reuse one instance instead of allocating per event. The class
    /// is documented as thread-safe for `string(from:)` calls, so the
    /// immutable shared instance is safe to read concurrently even though
    /// `ISO8601DateFormatter` is not `Sendable` — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    private let lock = NSLock()
    private let logger: Logger

    // Buffer
    private var buffer: [[String: Any]] = []
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
    private let flushIntervalMs: Int = 100
    private let maxBatchBytes: Int = 25 * 1024
    private let rateLimit: Int = 300
    private let burstCap: Int = 60
    private let maxPersistedBytes: Int = 1024 * 1024
    private let contextBlobLimit: Int = 1024

    // Dependencies
    var sendMessage: ((String) async throws -> Void)?
    var getConnectionId: (() -> String?)?
    var getUserId: (() -> String?)?
    var offlineStore: OfflineStore?
    var appId: String = ""

    /// Test-observability hook: invoked with the fully-prepared event right
    /// before it is buffered. Internal (visible only via `@testable import`)
    /// — the live-integration analytics tests use it to observe auto-events
    /// (#963) the same way the JS tests observe `client.analyticsQueue`.
    /// Never set in production code.
    var onEventLogged: (([String: Any]) -> Void)?

    /// Test-observability hook: invoked once each time `scheduleFlush()`
    /// actually creates a new flush timer (not on calls that find one
    /// already scheduled). Internal (visible only via `@testable import`)
    /// — the #1985 concurrency test uses it to assert that a burst of
    /// concurrent `logEvent`s schedules exactly one timer. Never set in
    /// production code.
    var onFlushScheduled: (() -> Void)?

    public init(logger: Logger) {
        self.logger = logger.forScope(scope: "analytics")
    }

    // MARK: - Overrides

    /// Override the plan field on all subsequent analytics events.
    public func setPlanOverride(_ plan: String?) {
        lock.withLock { planOverride = plan }
    }

    /// Override the app version field on all subsequent analytics events.
    public func setAppVersionOverride(_ version: String?) {
        lock.withLock { appVersionOverride = version }
    }

    // MARK: - Event Logging

    /// Typed entry point used by `client.analytics.logEvent(_:)`. Bridges
    /// to the untyped `[String: Any]` path below (which the llm/gemini
    /// `AnalyticsContext` callers also use), so all events funnel through
    /// the same defaulting / override / rate-limit logic.
    public func logEvent(_ event: AnalyticsEventInput) {
        logEvent(event.asDictionary())
    }

    public func logEvent(_ event: [String: Any]) {
        guard isWithinRateLimit() else {
            logger.debug("Analytics rate limit exceeded, dropping event")
            return
        }

        var preparedEvent = event
        if preparedEvent["user_ulid"] == nil {
            preparedEvent["user_ulid"] = getUserId?() ?? Self.unauthenticatedUser
        }
        preparedEvent["timestamp"] = Self.timestampFormatter.string(from: Date())

        // Apply overrides
        lock.withLock {
            if let plan = planOverride { preparedEvent["plan"] = plan }
            if let version = appVersionOverride { preparedEvent["app_version"] = version }
        }

        // Trim context_json if too large
        if let contextJson = preparedEvent["context_json"] as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: contextJson), data.count > contextBlobLimit {
                preparedEvent["context_json"] = nil
            }
        }

        lock.withLock { buffer.append(preparedEvent) }

        onEventLogged?(preparedEvent)

        scheduleFlush()
    }

    // MARK: - Flush

    public func flush() {
        let events: [[String: Any]] = lock.withLock {
            let events = buffer
            buffer.removeAll()
            return events
        }
        guard !events.isEmpty else { return }

        guard let connectionId = getConnectionId?() else {
            // Re-buffer for later
            lock.withLock { buffer.insert(contentsOf: events, at: 0) }
            return
        }

        let message: [String: Any] = [
            "type": "analytics.batch",
            "connection_id": connectionId,
            "events": events,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let task: Task<Void, Never> = Task {
            do {
                try await sendMessage?(jsonString)
            } catch {
                // Persist failed events
                lock.withLock { buffer.insert(contentsOf: events, at: 0) }
                await persistBuffer()
            }
        }
        lock.withLock { pendingFlushTask = task }
    }

    /// Wait for any in-flight flush task to drain. Called from
    /// `JsBaoClient.destroy()` after `destroy()` cancels the periodic
    /// flush timer and triggers the final flush — without awaiting,
    /// the persist-on-failure path could race the SQLite close.
    public func awaitPendingPersistence() async {
        let task = lock.withLock { pendingFlushTask }
        await task?.value
    }

    // MARK: - Persistence

    public func persistBuffer() async {
        // Enforce the persisted-bytes cap (oldest-event eviction) before
        // reading the buffer to persist, mirroring the JS client's
        // `enforcePersistenceCap()` which trims the buffer in place ahead
        // of every persist (analyticsQueue.ts).
        enforcePersistenceCap()

        let events = lock.withLock { buffer }

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
        lock.withLock {
            var totalBytes = estimatedBufferBytes(buffer)
            if totalBytes <= maxPersistedBytes { return }

            logger.warn(
                "Offline analytics queue exceeded capacity; truncating oldest events",
                "totalBytes=\(totalBytes) limit=\(maxPersistedBytes)"
            )

            while !buffer.isEmpty && totalBytes > maxPersistedBytes {
                buffer.removeFirst()
                totalBytes = estimatedBufferBytes(buffer)
            }
        }
    }

    /// UTF-8 byte length of the JSON-serialized events, matching JS's
    /// `estimatedBufferBytes` (`utf8ByteLength(JSON.stringify(events))`).
    /// Returns 0 for an empty buffer.
    private func estimatedBufferBytes(_ events: [[String: Any]]) -> Int {
        if events.isEmpty { return 0 }
        guard let data = try? JSONSerialization.data(withJSONObject: events) else { return 0 }
        return data.count
    }

    public func restoreBuffer() async {
        guard let userId = getUserId?() else { return }

        do {
            let events = try await offlineStore?.loadAnalyticsQueue(appId: appId, userId: userId) ?? []
            if !events.isEmpty {
                lock.withLock { buffer.insert(contentsOf: events, at: 0) }
                scheduleFlush()
            }
        } catch {
            logger.warn("Failed to restore analytics queue:", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    public func destroy() {
        // Read and clear the timer under the lock (same synchronization as
        // scheduleFlush), then cancel and flush outside it — flush() takes the
        // lock itself, so we must not hold it here (issue #1985).
        let timer: Task<Void, Never>? = lock.withLock {
            let current = flushTimer
            flushTimer = nil
            return current
        }
        timer?.cancel()
        flush()
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
        // the assignment both happen under the SAME lock hold, so two
        // concurrent `logEvent`s can't both see "no timer" and each schedule
        // one (issue #1985). Creating the Task doesn't run its body or take
        // the lock, so doing it under the lock introduces no re-entrancy — the
        // timer's own body (sleep, then flush) runs later, outside this hold.
        let created: Bool = lock.withLock {
            guard flushTimer == nil else { return false }
            flushTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.flushIntervalMs ?? 100) * 1_000_000)
                guard let self else { return }
                self.lock.withLock { self.flushTimer = nil }
                self.flush()
            }
            return true
        }
        // Fire the test hook outside the lock, and only for the single racer
        // that actually created the timer.
        if created { onFlushScheduled?() }
    }

    private func isWithinRateLimit() -> Bool {
        lock.withLock {
            let now = Date()
            let windowElapsed = now.timeIntervalSince(rateWindowStart)

            if windowElapsed >= 60 {
                rateCounter = 0
                rateWindowStart = now
            }

            if rateCounter >= rateLimit {
                return false
            }

            // Burst check
            if rateCounter >= burstCap && windowElapsed < 10 {
                return false
            }

            rateCounter += 1
            return true
        }
    }
}
