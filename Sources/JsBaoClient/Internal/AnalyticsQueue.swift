import Foundation

/// Batches and sends analytics events, with rate limiting and persistence.
public final class AnalyticsQueue: @unchecked Sendable {
    public static let unauthenticatedUser = "UNAUTHENTICATED"

    private let lock = NSLock()
    private let logger: Logger

    // Buffer
    private var buffer: [[String: Any]] = []
    private var flushTimer: Task<Void, Never>?
    private var rateCounter = 0
    private var rateWindowStart: Date = Date()

    // Overrides
    private var planOverride: String?
    private var appVersionOverride: String?

    // Config
    private let flushIntervalMs: Int = 100
    private let maxBatchBytes: Int = 25 * 1024
    private let rateLimit: Int = 300
    private let burstCap: Int = 60
    private let maxPersistedBytes: Int = 1_000_000
    private let contextBlobLimit: Int = 1024

    // Dependencies
    var sendMessage: ((String) async throws -> Void)?
    var getConnectionId: (() -> String?)?
    var getUserId: (() -> String?)?
    var offlineStore: OfflineStore?
    var appId: String = ""

    public init(logger: Logger) {
        self.logger = logger.forScope(scope: "analytics")
    }

    // MARK: - Overrides

    /// Override the plan field on all subsequent analytics events.
    public func setPlanOverride(_ plan: String?) {
        lock.lock()
        planOverride = plan
        lock.unlock()
    }

    /// Override the app version field on all subsequent analytics events.
    public func setAppVersionOverride(_ version: String?) {
        lock.lock()
        appVersionOverride = version
        lock.unlock()
    }

    // MARK: - Event Logging

    public func logEvent(_ event: [String: Any]) {
        guard isWithinRateLimit() else {
            logger.debug("Analytics rate limit exceeded, dropping event")
            return
        }

        var preparedEvent = event
        if preparedEvent["user_ulid"] == nil {
            preparedEvent["user_ulid"] = getUserId?() ?? Self.unauthenticatedUser
        }
        preparedEvent["timestamp"] = ISO8601DateFormatter().string(from: Date())

        // Apply overrides
        lock.lock()
        if let plan = planOverride { preparedEvent["plan"] = plan }
        if let version = appVersionOverride { preparedEvent["app_version"] = version }
        lock.unlock()

        // Trim context_json if too large
        if let contextJson = preparedEvent["context_json"] as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: contextJson), data.count > contextBlobLimit {
                preparedEvent["context_json"] = nil
            }
        }

        lock.lock()
        buffer.append(preparedEvent)
        lock.unlock()

        scheduleFlush()
    }

    // MARK: - Flush

    public func flush() {
        lock.lock()
        guard !buffer.isEmpty else {
            lock.unlock()
            return
        }
        let events = buffer
        buffer.removeAll()
        lock.unlock()

        guard let connectionId = getConnectionId?() else {
            // Re-buffer for later
            lock.lock()
            buffer.insert(contentsOf: events, at: 0)
            lock.unlock()
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

        Task {
            do {
                try await sendMessage?(jsonString)
            } catch {
                // Persist failed events
                lock.lock()
                buffer.insert(contentsOf: events, at: 0)
                lock.unlock()
                await persistBuffer()
            }
        }
    }

    // MARK: - Persistence

    public func persistBuffer() async {
        lock.lock()
        let events = buffer
        lock.unlock()

        guard !events.isEmpty, let userId = getUserId?() else { return }

        do {
            try await offlineStore?.persistAnalyticsQueue(appId: appId, userId: userId, events: events)
        } catch {
            logger.warn("Failed to persist analytics queue:", error.localizedDescription)
        }
    }

    public func restoreBuffer() async {
        guard let userId = getUserId?() else { return }

        do {
            let events = try await offlineStore?.loadAnalyticsQueue(appId: appId, userId: userId) ?? []
            if !events.isEmpty {
                lock.lock()
                buffer.insert(contentsOf: events, at: 0)
                lock.unlock()
                scheduleFlush()
            }
        } catch {
            logger.warn("Failed to restore analytics queue:", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    public func destroy() {
        flushTimer?.cancel()
        flushTimer = nil
        flush()
    }

    // MARK: - Private

    private func scheduleFlush() {
        lock.lock()
        guard flushTimer == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        flushTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.flushIntervalMs ?? 100) * 1_000_000)
            self?.flushTimer = nil
            self?.flush()
        }
    }

    private func isWithinRateLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }

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
