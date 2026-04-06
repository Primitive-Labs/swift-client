import Foundation

/// Thread-safe event emitter supporting typed event handlers
public final class EventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: [ObjectIdentifier: AnyObject]] = [:]
    private var closureHandlers: [String: [(Any) -> Void]] = [:]
    private var nextHandlerId: UInt64 = 0

    public init() {}

    /// Subscribe to an event with a typed handler. Returns a cancellable subscription.
    @discardableResult
    public func on<T>(_ event: JsBaoEvent, handler: @escaping (T) -> Void) -> EventSubscription {
        let id = allocateId()
        let wrapper = ClosureWrapper(id: id, handler: handler)
        lock.lock()
        var list = closureHandlers[event.rawValue] ?? []
        list.append { value in
            if let typed = value as? T {
                handler(typed)
            }
        }
        closureHandlers[event.rawValue] = list
        lock.unlock()
        return EventSubscription { [weak self] in
            self?.removeClosure(event: event.rawValue, at: list.count - 1)
        }
    }

    /// Subscribe to an event, receiving the raw Any payload
    @discardableResult
    public func onAny(_ event: JsBaoEvent, handler: @escaping (Any) -> Void) -> EventSubscription {
        lock.lock()
        var list = closureHandlers[event.rawValue] ?? []
        let index = list.count
        list.append(handler)
        closureHandlers[event.rawValue] = list
        lock.unlock()
        return EventSubscription { [weak self] in
            self?.removeClosure(event: event.rawValue, at: index)
        }
    }

    /// Emit an event with a payload
    public func emit(_ event: JsBaoEvent, _ payload: Any) {
        lock.lock()
        let list = closureHandlers[event.rawValue] ?? []
        lock.unlock()
        for handler in list {
            handler(payload)
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

    private func removeClosure(event: String, at index: Int) {
        lock.lock()
        guard var list = closureHandlers[event], index < list.count else {
            lock.unlock()
            return
        }
        list.remove(at: index)
        closureHandlers[event] = list
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

// MARK: - Internal helpers

private final class ClosureWrapper<T> {
    let id: UInt64
    let handler: (T) -> Void
    init(id: UInt64, handler: @escaping (T) -> Void) {
        self.id = id
        self.handler = handler
    }
}
