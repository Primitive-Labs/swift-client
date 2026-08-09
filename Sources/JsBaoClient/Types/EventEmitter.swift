import Foundation

/// The client's event registry.
///
/// One registry serves both delivery shapes so they cannot diverge:
///
/// - **`AsyncStream` consumers** — created through `JsBaoClient.stream(for:)`,
///   `observeOnMainActor(_:handler:)` and `nextEvent(_:)`. This is the supported
///   surface.
/// - **Callback subscribers** — the typed `subscribe(_:)` registrations behind
///   `observeOnMainActor`. Delivery is synchronous, inside `emit`, in
///   registration order. Wrapping them over a stream would have made that
///   asynchronous and changed the timing every consumer sees, so both shapes
///   fan out from the same `emit` instead.
///
/// The untyped `on` / `onAny` shim this registry also used to serve was removed
/// in #2367; only the typed shapes above remain.
public final class EventEmitter: @unchecked Sendable {
    private struct CallbackEntry {
        let id: UInt64
        /// Handed the payload and the delivery metadata captured for that emit.
        /// Subscribers that do not want the metadata discard the second
        /// argument, so there is one delivery path rather than two.
        let handler: (Any, EventDelivery) -> Void
    }

    /// One `AsyncStream` consumer. `yield` forwards a matching payload into that
    /// consumer's continuation and does the high-water accounting.
    private struct StreamEntry {
        let id: UInt64
        let yield: (Any) -> Void
        /// Ends the consumer's stream. Called when the emitter goes away, so a
        /// `for await` loop exits instead of hanging on a continuation that will
        /// never be yielded to again.
        let finish: () -> Void
    }

    private let lock = NSLock()
    private var closureHandlers: [String: [CallbackEntry]] = [:]
    private var streamHandlers: [String: [StreamEntry]] = [:]
    private var nextHandlerId: UInt64 = 0
    /// Emit counter behind ``EventDelivery/sequence``. Incremented once per
    /// `dispatch`, inside the critical section that already snapshots the
    /// handler lists — so the numbers are handed out in the order emits entered
    /// that section, and no second lock acquisition is added to the emit path.
    private var nextEmitSequence: UInt64 = 0
    /// Most recent value of each replayable event key, for
    /// `stream(for:replayingLatest: true)`. Bounded by
    /// `replayableEventKeys` — a handful of state-like events, never the
    /// high-frequency ones.
    private var latestByKey: [String: Any] = [:]
    /// Set by `finishAllStreams()`. Once the emitter is closed a new stream is
    /// handed back already finished rather than registered, so a `for await`
    /// opened after teardown exits instead of waiting on a client that is gone.
    private var closed = false
    /// Backing store for `lastStreamMeter`, guarded by `lock`.
    private var lastStreamMeterStorage: StreamMeter?
    private let logger: Logger?

    /// Event keys whose latest value is retained for replay: the state-like
    /// events whose payload describes a condition that is still true after the
    /// event fired. Derived from `JsBaoEventPayload.isReplayable`, so there is
    /// no second list to drift.
    static let replayableEventKeys: Set<String> = Set(
        allJsBaoEventPayloadTypes
            .filter { $0.isReplayable }
            .map { $0.eventKey.rawValue }
    )

    public init() {
        self.logger = nil
    }

    /// Internal initializer that wires a logger, so the stalled-consumer
    /// high-water warning has somewhere to go.
    init(logger: Logger?) {
        self.logger = logger
    }

    // MARK: - Callback subscription

    /// Remove all callback handlers for an event.
    ///
    /// Streams are deliberately untouched: a `stream(for:)` consumer owns its own
    /// subscription's lifetime through its `for await` loop, and ending someone
    /// else's loop from here would be a surprising reach across that boundary.
    /// To end every open stream — on client teardown — use `finishAllStreams()`.
    ///
    /// The removed entries are claimed under the lock and released after it is
    /// dropped — see ``removeAll()`` for why.
    public func removeAll(for event: JsBaoEvent) {
        let claimed = lock.withLock { closureHandlers.removeValue(forKey: event.rawValue) }
        _ = claimed
    }

    /// Remove all callback handlers. Streams are untouched — see
    /// `removeAll(for:)`.
    ///
    /// The handler storage is claimed under the lock and released only after
    /// the lock is dropped. Releasing a handler can run the `deinit` of a
    /// consumer the closure was the last strong reference to, and a `deinit`
    /// that cancels its subscriptions re-enters the emitter through
    /// ``removeClosure(event:id:)`` — on the same thread, against the same
    /// non-recursive `NSLock`. Doing that inside the critical section parks the
    /// thread forever (issue #2574). This is the same discipline
    /// `EventSubscription.cancel()` and `finishAllStreams()` already follow.
    public func removeAll() {
        let claimed = lock.withLock { () -> [String: [CallbackEntry]] in
            let all = closureHandlers
            closureHandlers.removeAll()
            return all
        }
        _ = claimed
    }

    /// End every open stream and close the emitter.
    ///
    /// Releasing an `AsyncStream.Continuation` does not finish its stream, so
    /// without this a consumer awaiting an event from a client that has gone away
    /// would hang forever. Called from `JsBaoClient.destroy()` and from `deinit`.
    ///
    /// Also drops the retained replay values — they describe a client that no
    /// longer exists, and keeping them would both outlive teardown and hand a
    /// post-`destroy()` `replayingLatest:` consumer a pre-teardown value.
    func finishAllStreams() {
        let entries = lock.withLock { () -> [StreamEntry] in
            let all = streamHandlers.values.flatMap { $0 }
            streamHandlers.removeAll()
            latestByKey.removeAll()
            closed = true
            return all
        }
        for entry in entries {
            entry.finish()
        }
    }

    deinit {
        finishAllStreams()
    }

    // MARK: - Typed emit

    /// Emit a payload under the one key its type declares.
    ///
    /// This is the emit side of the compile-time association: the key comes from
    /// `E.eventKey`, so a payload can no longer be emitted under a key nothing
    /// subscribes to it on.
    func emit<E: JsBaoEventPayload>(_ payload: E) {
        dispatch(key: E.eventKey.rawValue, payload: payload)
    }

    /// Emit a payload whose concrete type is only known at runtime — the shape
    /// the injected `KvCache` emit closure hands over. The key still comes from
    /// the payload's own type, so nothing can pair them wrongly.
    func emitErased(_ payload: any JsBaoEventPayload) {
        dispatch(key: Swift.type(of: payload).eventKey.rawValue, payload: payload)
    }

    // MARK: - Typed callback subscription (internal, non-deprecated)

    /// Register a typed callback, delivered synchronously inside `emit` in
    /// registration order.
    ///
    /// This is what the client's own listeners use — they need the payload type
    /// checked but not a main-actor hop or an async loop — and what
    /// `observeOnMainActor` and `nextEvent` are built on.
    @discardableResult
    func subscribe<E: JsBaoEventPayload>(
        _ type: E.Type,
        handler: @escaping (E) -> Void
    ) -> EventSubscription {
        subscribe(type, withDelivery: { payload, _ in handler(payload) })
    }

    /// The same registration, with the emit's ``EventDelivery`` alongside the
    /// payload. Backs `JsBaoClient.observeOnMainActor(_:withDelivery:)`.
    ///
    /// Additive on purpose: `subscribe(_:handler:)` above keeps its signature,
    /// so the client's own listeners that do not care about the metadata are
    /// untouched, and both forms register the same kind of entry.
    @discardableResult
    func subscribe<E: JsBaoEventPayload>(
        _ type: E.Type,
        withDelivery handler: @escaping (E, EventDelivery) -> Void
    ) -> EventSubscription {
        let key = E.eventKey.rawValue
        let id = allocateId()
        addCallback(event: key, id: id) { value, delivery in
            guard let typed = value as? E else { return }
            handler(typed, delivery)
        }
        return EventSubscription { [weak self] in
            self?.removeClosure(event: key, id: id)
        }
    }

    // MARK: - Streams

    /// Open an `AsyncStream` of one event.
    ///
    /// Backs `JsBaoClient.stream(for:buffering:replayingLatest:)` — see that
    /// method for the consumer-facing contract.
    func makeStream<E: JsBaoEventPayload>(
        for type: E.Type,
        buffering: AsyncStream<E>.Continuation.BufferingPolicy,
        replayingLatest: Bool
    ) -> AsyncStream<E> {
        let key = E.eventKey.rawValue
        let id = allocateId()
        let meter = StreamMeter(eventKey: key, logger: logger)
        let (inner, continuation) = AsyncStream<E>.makeStream(bufferingPolicy: buffering)

        // Registered before the entry is added so a yield can never race a
        // consumer that has already gone away without the entry being removed.
        //
        // This handler takes `lock`, and `finish()` runs it synchronously on the
        // calling thread, so nothing may call `finish()` while `lock` is held.
        continuation.onTermination = { [weak self] _ in
            self?.removeStream(event: key, id: id)
        }

        // Only an element the buffer actually accepted is outstanding. A bounded
        // policy drops instead of enqueueing — `.bufferingNewest(1)` evicts the
        // previous element and reports `.dropped` — and counting those as
        // pending would grow the meter without limit however promptly the
        // consumer drains, then advise a consumer already on
        // `.bufferingNewest(1)` to switch to it.
        let deliver: (E) -> Void = { typed in
            if case .enqueued = continuation.yield(typed) {
                meter.noteYield()
            }
        }

        // Register, and replay the retained value, in the same critical section.
        // Doing the replay yield off-lock would only stop a *duplicate*
        // delivery, not a reordered one: an emit landing between the two takes
        // the off-lock `dispatch` path, finds this entry registered, and yields
        // the newer value first — leaving a `replayingLatest: true` consumer
        // parked on the older one. Holding the lock across the yield means a
        // concurrent emit either snapshots before this entry exists (so it is
        // not delivered here at all) or blocks until the replayed value is in
        // the buffer. Nothing can be iterating yet — the stream has not been
        // returned to the caller — so the yield cannot re-enter.
        //
        // `nil` means the emitter is closed and nothing was registered; `true` /
        // `false` mean the entry is registered and the retained value was or was
        // not replayed into it.
        let didReplay: Bool? = lock.withLock {
            guard !closed else { return nil }
            lastStreamMeterStorage = meter
            var list = streamHandlers[key] ?? []
            list.append(StreamEntry(
                id: id,
                yield: { value in
                    guard let typed = value as? E else { return }
                    deliver(typed)
                },
                finish: { continuation.finish() }
            ))
            streamHandlers[key] = list
            guard replayingLatest, let replayed = latestByKey[key] as? E else { return false }
            deliver(replayed)
            return true
        }

        if didReplay == nil {
            // Finished OUTSIDE the lock: `finish()` runs `onTermination`
            // synchronously, and that handler takes the same lock.
            continuation.finish()
        }

        if replayingLatest, didReplay != true, !E.isReplayable {
            logger?.debug(
                "stream(for:replayingLatest: true) has nothing to replay — this event's latest value is not retained",
                "event:", key
            )
        }

        // The returned stream wraps `inner` so consumption can be counted: an
        // `AsyncStream` exposes no buffer depth, and without the consume side
        // the high-water warning could not tell a fast consumer from a stalled
        // one.
        //
        // Teardown chains through the wrapper without changing `AsyncStream`'s
        // lifetime rule. The returned stream and its iterators share one
        // context, which holds the produce closure below; when the last of them
        // goes away that closure — and with it `StreamIteratorBox` and `inner`'s
        // own iterator — is released, `inner`'s context deinitializes, and
        // `onTermination` above removes the registry entry. So a caller who
        // retains the returned value keeps the subscription alive after ending
        // the loop, precisely as a retained bare `AsyncStream` does
        // (`EventStreamTests.testBareAsyncStreamHasTheSameRetainedLifetime` pins
        // the reference behavior); the `stream(for:)` doc comment states it.
        // Nothing here can hook a single iterator's deinit — `AsyncStream`
        // exposes no such hook — so this is a contract to document, not a leak
        // to close.
        let iterator = StreamIteratorBox(inner.makeAsyncIterator())
        return AsyncStream<E> {
            let next = await iterator.next()
            if next != nil { meter.noteConsumed() }
            return next
        } onCancel: {
            continuation.finish()
        }
    }

    // MARK: - Introspection (tests)

    /// Total number of registered callback handlers across all events. Internal,
    /// read only — used by tests (e.g. the `waitFor` cancellation regression) to
    /// assert that subscriptions are actually removed and nothing leaks.
    internal var activeHandlerCount: Int {
        lock.withLock { closureHandlers.values.reduce(0) { $0 + $1.count } }
    }

    /// Total number of live `AsyncStream` consumers across all events. The
    /// stream-side counterpart of `activeHandlerCount`: the leak regression
    /// tests assert this returns to its pre-subscription value once a `for await`
    /// loop ends, its task is cancelled, or the stream is dropped.
    internal var activeObserverCount: Int {
        lock.withLock { streamHandlers.values.reduce(0) { $0 + $1.count } }
    }

    /// The `StreamMeter` created for the most recently opened stream. The
    /// high-water warning is the only part of the stream contract with no
    /// observable output of its own (it logs at debug level), so without this
    /// hook a test could not tell a wired meter from a dead one — deleting both
    /// `noteYield()` and `noteConsumed()` used to leave the suite green.
    internal var lastStreamMeter: StreamMeter? {
        lock.withLock { lastStreamMeterStorage }
    }

    // MARK: - Private

    /// Fan out one payload to both delivery shapes.
    ///
    /// The registry lock is held only to snapshot the entries (and retain the
    /// value for a replayable key); delivery happens off-lock. That is what makes
    /// a re-entrant emit from a callback safe, and what lets `yield` run without
    /// the lock. An entry cancelled between the snapshot and the yield receives
    /// one final yield into an already-finished continuation, which
    /// `AsyncStream` discards.
    private func dispatch(key: String, payload: Any) {
        let (callbacks, streams, delivery) = lock.withLock {
            () -> ([CallbackEntry], [StreamEntry], EventDelivery) in
            if Self.replayableEventKeys.contains(key) {
                latestByKey[key] = payload
            }
            // Captured here, not at handler-run time: a subscriber that is
            // delivered a hop later must still be able to report when the
            // client emitted. Taken inside the existing critical section so the
            // sequence a payload carries matches the order emits were admitted.
            nextEmitSequence += 1
            let delivery = EventDelivery(emittedAt: Date(), sequence: nextEmitSequence)
            return (closureHandlers[key] ?? [], streamHandlers[key] ?? [], delivery)
        }
        for entry in callbacks {
            entry.handler(payload, delivery)
        }
        for entry in streams {
            entry.yield(payload)
        }
    }

    private func addCallback(event: String, id: UInt64, handler: @escaping (Any, EventDelivery) -> Void) {
        lock.withLock {
            var list = closureHandlers[event] ?? []
            list.append(CallbackEntry(id: id, handler: handler))
            closureHandlers[event] = list
        }
    }

    private func allocateId() -> UInt64 {
        lock.withLock {
            nextHandlerId += 1
            return nextHandlerId
        }
    }

    /// Cancelling one subscription. The removed entry is claimed under the lock
    /// and released outside it, for the same reason ``removeAll()`` documents:
    /// releasing a handler can run a consumer's `deinit`, which may cancel
    /// another subscription and re-enter this non-recursive lock on this thread.
    private func removeClosure(event: String, id: UInt64) {
        let claimed = lock.withLock { () -> [CallbackEntry] in
            guard var list = closureHandlers[event] else { return [] }
            var removed: [CallbackEntry] = []
            list.removeAll { entry in
                guard entry.id == id else { return false }
                removed.append(entry)
                return true
            }
            closureHandlers[event] = list
            return removed
        }
        _ = claimed
    }

    private func removeStream(event: String, id: UInt64) {
        lock.withLock {
            if var list = streamHandlers[event] {
                list.removeAll { $0.id == id }
                streamHandlers[event] = list.isEmpty ? nil : list
            }
        }
    }
}

// MARK: - Stream plumbing

/// Holds one stream's iterator so the wrapping `AsyncStream(unfolding:)` closure
/// can advance it.
///
/// `AsyncStream` calls that closure serially for a single consumer, but two
/// tasks iterating the *same* stream value both enter it, so the stored iterator
/// is copied out under a lock and the copy is advanced. Overlapping exclusive
/// access to the stored property would be a data race the plain `AsyncStream`
/// this wraps does not have. An `AsyncStream` iterator is a thin handle onto
/// shared storage, so the copy consumes from the same buffer — the behavior two
/// iterators of a bare `AsyncStream` already have.
private final class StreamIteratorBox<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncStream<Element>.AsyncIterator

    init(_ iterator: AsyncStream<Element>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async -> Element? {
        var advancing = lock.withLock { iterator }
        return await advancing.next()
    }
}

/// Tracks how far behind one stream's consumer is running.
///
/// `.unbounded` buffering never drops an event, which is what the connection and
/// document-lifecycle events need, but it means a consumer that stops draining
/// grows the buffer without limit. Rather than silently accumulate, the meter
/// logs once when a stream passes `highWaterMark` undrained elements, naming the
/// event key so a stuck consumer is diagnosable from a device log.
///
/// Only elements the buffer accepted are counted, so a bounded policy — where
/// `AsyncStream` drops rather than enqueues — never trips the warning however
/// long its consumer stalls. `pendingCount` is the buffer depth under every
/// policy, not the number of yields.
final class StreamMeter: @unchecked Sendable {
    /// Undrained elements at which the warning fires, once per stream.
    static let highWaterMark = 1_000

    private let lock = NSLock()
    private var pending = 0
    private var warned = false
    private let eventKey: String
    private let logger: Logger?

    init(eventKey: String, logger: Logger?) {
        self.eventKey = eventKey
        self.logger = logger
    }

    /// Count one element the stream's buffer accepted. Callers must not count a
    /// yield the buffering policy dropped — see `makeStream`'s `deliver`.
    func noteYield() {
        let outstanding = lock.withLock { () -> Int? in
            pending += 1
            guard pending >= Self.highWaterMark, !warned else { return nil }
            warned = true
            return pending
        }
        guard let outstanding else { return }
        logger?.debug(
            "Event stream consumer is falling behind",
            "event:", eventKey,
            "undrained:", outstanding,
            "— pass buffering: .bufferingNewest(1) if only the latest value matters"
        )
    }

    func noteConsumed() {
        lock.withLock {
            if pending > 0 { pending -= 1 }
        }
    }

    /// Undrained element count. Read by the buffering tests.
    var pendingCount: Int { lock.withLock { pending } }

    /// Whether the high-water warning has fired. Read by the buffering tests.
    var didWarn: Bool { lock.withLock { warned } }
}

// MARK: - Subscriptions

/// A cancellable event subscription.
///
/// Construct one directly when wrapping a non-`EventEmitter` cancel
/// closure — most commonly `DynamicModel.subscribe()`'s unsubscribe
/// block — for use with `BaoDataLoader`'s `.custom` trigger
/// (issue #854). Owns the closure and cancels exactly once on
/// `cancel()` or `deinit`.
public final class EventSubscription: @unchecked Sendable {
    /// Guards `cancellation` so `cancel()` racing `deinit` (or two concurrent
    /// `cancel()` calls) still runs the closure exactly once. Without it the
    /// read-then-nil pair was a data race — the one #1910's ThreadSanitizer
    /// baseline recorded against this type.
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    public init(cancel: @escaping () -> Void) {
        self.cancellation = cancel
    }

    public func cancel() {
        // Claim the closure under the lock, then run it outside — a cancel
        // closure that re-enters the emitter must not do so while this lock is
        // held.
        let claimed = lock.withLock { () -> (() -> Void)? in
            let current = cancellation
            cancellation = nil
            return current
        }
        claimed?()
    }

    deinit {
        cancel()
    }
}

/// One-way cancelled flag shared between an `observeOnMainActor` subscription
/// and the main-queue hops it has already enqueued.
///
/// Cancelling the subscription only removes the emitter-side callback, which
/// says nothing about an event that was already emitted and whose hop is sitting
/// in the main queue. That hop reads this flag before calling the handler, so a
/// `cancel()` on the main actor is honoured by every hop behind it — the main
/// queue is FIFO, so all of them are.
final class MainActorDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// Holds the handles one wait owns — its event subscription and, when there is
/// one, its timeout task — and settles exactly once.
///
/// This is the one copy of "resume once, then tear down" in the client. A
/// handler can fire on another thread before `subscribe` has returned to the
/// caller, so a plain captured `var sub: EventSubscription?` is a data race —
/// the second `EventSubscription` entry in #1910's ThreadSanitizer baseline.
/// Storing the handles here orders them under a lock, and a `claim()` that
/// arrives before `set(_:)` cancels the subscription the moment it is stored, so
/// an early-firing handler tears the subscription down rather than leaking the
/// registry entry.
final class SubscriptionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: EventSubscription?
    private var timeoutTask: Task<Void, Never>?
    private var settled = false

    /// Store the event subscription, cancelling it straight away if the wait has
    /// already settled.
    func set(_ subscription: EventSubscription) {
        let alreadySettled = lock.withLock { () -> Bool in
            guard !settled else { return true }
            self.subscription = subscription
            return false
        }
        if alreadySettled { subscription.cancel() }
    }

    /// Store the timeout task, with the same already-settled handling.
    func set(timeoutTask: Task<Void, Never>) {
        let alreadySettled = lock.withLock { () -> Bool in
            guard !settled else { return true }
            self.timeoutTask = timeoutTask
            return false
        }
        if alreadySettled { timeoutTask.cancel() }
    }

    /// Whether the wait has settled. Read by callers that poll rather than
    /// resume — the `openDocument` retry tick, which stops re-sending once the
    /// sync it is waiting for has landed.
    var isSettled: Bool { lock.withLock { settled } }

    /// Returns `true` for the one caller that gets to settle the wait, and tears
    /// both handles down as it does. Every later caller gets `false`.
    ///
    /// Both handles are claimed under the lock and cancelled outside it, so a
    /// cancel closure that re-enters the emitter cannot deadlock and the stored
    /// fields are never read concurrently with `set`.
    @discardableResult
    func claim() -> Bool {
        let claimed = lock.withLock { () -> (EventSubscription?, Task<Void, Never>?)? in
            guard !settled else { return nil }
            settled = true
            defer {
                subscription = nil
                timeoutTask = nil
            }
            return (subscription, timeoutTask)
        }
        guard let claimed else { return false }
        claimed.1?.cancel()
        claimed.0?.cancel()
        return true
    }

    /// Tear the wait down without caring whether this call was the one that
    /// settled it.
    func cancel() {
        _ = claim()
    }
}

/// One-shot bridge from `withTaskCancellationHandler`'s `onCancel` — which runs
/// outside the continuation's scope — to the continuation itself.
///
/// Ordered under a lock because cancellation can arrive before the continuation
/// exists: in that case the resume registered afterwards runs immediately, so
/// the caller is never left parked on a cancelled task.
final class CancellationBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var resume: (() -> Void)?
    private var cancelled = false

    func onCancelResume(_ resume: @escaping () -> Void) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            guard !cancelled else { return true }
            self.resume = resume
            return false
        }
        if alreadyCancelled { resume() }
    }

    func cancel() {
        let claimed = lock.withLock { () -> (() -> Void)? in
            cancelled = true
            let current = resume
            resume = nil
            return current
        }
        claimed?()
    }
}

// MARK: - Resume-once waiting

extension EventEmitter {
    /// Wait for the next occurrence of one typed event.
    ///
    /// Backs `JsBaoClient.nextEvent(_:timeout:where:)` — see that method for the
    /// caller-facing contract. `SubscriptionHolder` is the resume-once state: the
    /// handler, the timeout task and the cancellation handler all race to
    /// `claim()`, and exactly one wins.
    func waitForNextEvent<E: JsBaoEventPayload>(
        _ type: E.Type,
        timeout: TimeInterval,
        predicate: (@Sendable (E) -> Bool)?
    ) async throws -> E {
        let wait = SubscriptionHolder()
        let cancellation = CancellationBridge()
        // Cancelling the calling task — a SwiftUI `.task` whose view went away,
        // say — has to end the wait too. Without this the caller stays parked and
        // the handler stays registered for the rest of the timeout.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancellation.onCancelResume {
                    guard wait.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                }
                wait.set(subscribe(type) { payload in
                    if let predicate, !predicate(payload) { return }
                    guard wait.claim() else { return }
                    continuation.resume(returning: payload)
                })
                wait.set(timeoutTask: timeoutTask(
                    wait: wait,
                    timeout: timeout,
                    eventKey: E.eventKey.rawValue,
                    continuation: continuation
                ))
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func timeoutTask<T>(
        wait: SubscriptionHolder,
        timeout: TimeInterval,
        eventKey: String,
        continuation: CheckedContinuation<T, Error>
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard wait.claim() else { return }
            continuation.resume(throwing: JsBaoError(
                code: .unavailable,
                message: "Timeout waiting for event: \(eventKey)"
            ))
        }
    }
}
