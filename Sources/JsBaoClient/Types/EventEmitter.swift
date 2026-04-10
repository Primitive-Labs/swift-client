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
        lock.lock()
        var list = closureHandlers[event.rawValue] ?? []
        list.append(Entry(id: id, handler: wrapped))
        closureHandlers[event.rawValue] = list
        lock.unlock()
        return EventSubscription { [weak self] in
            self?.removeClosure(event: event.rawValue, id: id)
        }
    }

    /// Subscribe to an event, receiving the raw Any payload
    @discardableResult
    public func onAny(_ event: JsBaoEvent, handler: @escaping (Any) -> Void) -> EventSubscription {
        let id = allocateId()
        lock.lock()
        var list = closureHandlers[event.rawValue] ?? []
        list.append(Entry(id: id, handler: handler))
        closureHandlers[event.rawValue] = list
        lock.unlock()
        return EventSubscription { [weak self] in
            self?.removeClosure(event: event.rawValue, id: id)
        }
    }

    /// Emit an event with a payload
    public func emit(_ event: JsBaoEvent, _ payload: Any) {
        lock.lock()
        let list = closureHandlers[event.rawValue] ?? []
        lock.unlock()
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
        lock.lock()
        closureHandlers[event.rawValue] = nil
        lock.unlock()
    }

    /// Remove all handlers
    public func removeAll() {
        lock.lock()
        closureHandlers.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func allocateId() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextHandlerId += 1
        return nextHandlerId
    }

    private func removeClosure(event: String, id: UInt64) {
        lock.lock()
        if var list = closureHandlers[event] {
            list.removeAll { $0.id == id }
            closureHandlers[event] = list
        }
        lock.unlock()
    }
}

/// A cancellable event subscription
public final class EventSubscription: @unchecked Sendable {
    private var cancellation: (() -> Void)?

    init(cancel: @escaping () -> Void) {
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
    try await withCheckedThrowingContinuation { continuation in
        var subscription: EventSubscription?
        var timeoutTask: Task<Void, Never>?
        var resumed = false
        let lock = NSLock()

        subscription = emitter.onAny(event) { payload in
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            if let predicate = predicate, !predicate(payload) {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()
            timeoutTask?.cancel()
            subscription?.cancel()
            continuation.resume(returning: payload)
        }

        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()
            subscription?.cancel()
            continuation.resume(throwing: JsBaoError(code: .unavailable, message: "Timeout waiting for event: \(event.rawValue)"))
        }
    }
}

