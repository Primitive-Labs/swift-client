import Foundation

/// Thread-safe event emitter supporting typed event handlers
public final class EventEmitter: @unchecked Sendable {
    private struct Entry {
        let id: UInt64
        let handler: (Any) -> Void
    }

    private let lock = NSLock()
    private var closureHandlers: [String: [Entry]] = [:]
    private var nextHandlerId: UInt64 = 0

    public init() {}

    /// Subscribe to an event with a typed handler. Returns a cancellable subscription.
    @discardableResult
    public func on<T>(_ event: JsBaoEvent, handler: @escaping (T) -> Void) -> EventSubscription {
        let id = allocateId()
        let wrapped: (Any) -> Void = { value in
            if let typed = value as? T {
                handler(typed)
            }
        }
        lock.withLock {
            var list = closureHandlers[event.rawValue] ?? []
            list.append(Entry(id: id, handler: wrapped))
            closureHandlers[event.rawValue] = list
        }
        return EventSubscription { [weak self] in
            self?.removeClosure(event: event.rawValue, id: id)
        }
    }

    /// Subscribe to an event, receiving the raw Any payload
    @discardableResult
    public func onAny(_ event: JsBaoEvent, handler: @escaping (Any) -> Void) -> EventSubscription {
        let id = allocateId()
        lock.withLock {
            var list = closureHandlers[event.rawValue] ?? []
            list.append(Entry(id: id, handler: handler))
            closureHandlers[event.rawValue] = list
        }
        return EventSubscription { [weak self] in
            self?.removeClosure(event: event.rawValue, id: id)
        }
    }

    /// Emit an event with a payload
    public func emit(_ event: JsBaoEvent, _ payload: Any) {
        let list = lock.withLock { closureHandlers[event.rawValue] ?? [] }
        for entry in list {
            entry.handler(payload)
        }
    }

    /// Emit an event with no payload
    public func emit(_ event: JsBaoEvent) {
        emit(event, () as Any)
    }

    /// Remove all handlers for an event
    public func removeAll(for event: JsBaoEvent) {
        lock.withLock { closureHandlers[event.rawValue] = nil }
    }

    /// Remove all handlers
    public func removeAll() {
        lock.withLock { closureHandlers.removeAll() }
    }

    // MARK: - Private

    private func allocateId() -> UInt64 {
        lock.withLock {
            nextHandlerId += 1
            return nextHandlerId
        }
    }

    private func removeClosure(event: String, id: UInt64) {
        lock.withLock {
            if var list = closureHandlers[event] {
                list.removeAll { $0.id == id }
                closureHandlers[event] = list
            }
        }
    }
}

/// A cancellable event subscription.
///
/// Construct one directly when wrapping a non-`EventEmitter` cancel
/// closure — most commonly `DynamicModel.subscribe()`'s unsubscribe
/// block — for use with `BaoDataLoader`'s `.custom` trigger
/// (issue #854). Owns the closure and cancels exactly once on
/// `cancel()` or `deinit`.
public final class EventSubscription: @unchecked Sendable {
    private var cancellation: (() -> Void)?

    public init(cancel: @escaping () -> Void) {
        self.cancellation = cancel
    }

    public func cancel() {
        cancellation?()
        cancellation = nil
    }

    deinit {
        cancel()
    }
}

/// Helper to wait for an event with a timeout
public func waitForEvent(
    emitter: EventEmitter,
    event: JsBaoEvent,
    timeout: TimeInterval = 10,
    predicate: ((Any) -> Bool)? = nil
) async throws -> Any {
    // Shared resume-once state, guarded by an internal lock. Hoisted into an
    // `@unchecked Sendable` holder so the event handler closure and the
    // timeout `Task` capture one Sendable reference rather than mutable local
    // `var`s. Behavior is unchanged — the same lock still guards the same
    // resume-once flag; this only makes the safety the code already had
    // legible to the concurrency checker (matches the codebase's other
    // `@unchecked Sendable` + `NSLock` holders).
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var resumed = false
        var subscription: EventSubscription?
        var timeoutTask: Task<Void, Never>?
    }
    let state = State()

    return try await withCheckedThrowingContinuation { continuation in
        state.subscription = emitter.onAny(event) { payload in
            let shouldResume = state.lock.withLock { () -> Bool in
                guard !state.resumed else { return false }
                if let predicate = predicate, !predicate(payload) { return false }
                state.resumed = true
                return true
            }
            guard shouldResume else { return }
            state.timeoutTask?.cancel()
            state.subscription?.cancel()
            // `payload` is `Any` (non-Sendable); the resume-once guard above
            // guarantees a single hand-off, so annotate the capture as
            // reviewed-safe (same pattern as `unsafeDoc` in JsBaoClient).
            nonisolated(unsafe) let capturedPayload = payload
            continuation.resume(returning: capturedPayload)
        }

        state.timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            let shouldResume = state.lock.withLock { () -> Bool in
                guard !state.resumed else { return false }
                state.resumed = true
                return true
            }
            guard shouldResume else { return }
            state.subscription?.cancel()
            continuation.resume(throwing: JsBaoError(code: .unavailable, message: "Timeout waiting for event: \(event.rawValue)"))
        }
    }
}

