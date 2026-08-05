import Foundation

// Containment boxes the test target needs under the Swift 6 language mode
// (#2310). The two that carry an `@unchecked Sendable` claim follow the shape
// the library settled on for `QueueWork` in `SQLiteStorageProvider` (#2318):
// the claim covers a single stored property whose access discipline is stated
// right here, rather than being spread across the call sites with
// `nonisolated(unsafe)`.

/// Lock-guarded container for a value a test observes or mutates from inside a
/// `@Sendable` callback.
///
/// Under the Swift 6 language mode a test can no longer capture a local `var`
/// and mutate it from a concurrently-executing closure ("mutation of captured
/// var … in concurrently-executing code"), nor capture a non-`Sendable`
/// reference type into one. Both diagnostics say the same thing: the value
/// needs an owner that serialises access. `LockedBox` is that owner.
///
/// The containment shape is the one the library uses for `QueueWork` in
/// `SQLiteStorageProvider` (#2318): the `@unchecked Sendable` claim covers
/// exactly one stored property, and every read and write of that property goes
/// through `lock`, so there is no path to it that skips the lock.
///
/// This is test-support code — production code should reach for an actor or a
/// genuinely `Sendable` type first.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// Read-modify-write under a single lock acquisition. Use this instead of
    /// `box.value = f(box.value)` whenever the new value depends on the old
    /// one — the property form takes the lock twice and can interleave.
    ///
    /// Keep `body` to the mutation itself. Calling back into the library from
    /// inside it holds this lock across whatever that call waits on — several
    /// client entry points drain a serial queue with `dispatch_sync`, so a
    /// second thread already on that queue and waiting for this lock deadlocks
    /// both. Compute the value first, then hand the finished value to
    /// `withValue`.
    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&_value) }
    }
}

extension LockedBox where Value: AdditiveArithmetic {
    /// Convenience for the common counter case.
    func add(_ amount: Value) {
        withValue { $0 += amount }
    }
}

/// Lock-guarded weak reference, for the deallocation checks that poll from
/// inside a `@Sendable` closure.
///
/// The natural spelling — `weak var subject: T?` beside the object, then
/// `await eventuallyTrue { subject == nil }` — is a captured local `var` read
/// from concurrently-executing code, which the Swift 6 language mode rejects.
/// Boxing makes the capture a `let`, and serialises the weak read, which is
/// not itself thread-safe.
///
/// The reference stays weak, so the box does not keep the subject alive and
/// the test still measures what it means to measure. Same containment shape as
/// `LockedBox`: one stored property, reached only under `lock`.
final class WeakBox<Object: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var object: Object?

    init(_ object: Object?) { self.object = object }

    /// `true` once the subject has been deallocated.
    var isReleased: Bool { lock.withLock { object == nil } }
}

/// One-shot handover container for a non-`Sendable` value that has to cross an
/// isolation boundary exactly once — a `Task`'s success value, or a
/// `TaskGroup`'s child result type.
///
/// The safety argument is the handover itself: the producer builds the value,
/// stores it, and never touches it again; the consumer reads it after the
/// `await` that joins the two sides. There is no shared window, so no lock is
/// needed. Use `LockedBox` instead whenever both sides keep touching the value.
///
/// For `YDocument` specifically use the library's own `ConfinedYDocument` — it
/// carries the document's lock-confinement argument, which this box does not.
struct SendingBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Thread-safe stand-in for `NSCountedSet` in tests that tally callback fires
/// from inside a `@Sendable` handler. `NSCountedSet` is a non-`Sendable` class,
/// so capturing one in a handler is an error under the Swift 6 language mode;
/// this keeps the same two-call shape (`add` / `count(for:)`).
///
/// Plainly `Sendable`: its only stored property is a `LockedBox`, which owns
/// the unchecked claim, so this type needs none of its own.
final class FireCounter: Sendable {
    private let counts = LockedBox([String: Int]())

    func add(_ key: String) { counts.withValue { $0[key, default: 0] += 1 } }

    func count(for key: String) -> Int { counts.value[key] ?? 0 }

    /// Number of distinct keys seen — `NSCountedSet.count`.
    var count: Int { counts.value.count }
}

extension DispatchSemaphore {
    /// `wait(timeout:)` blocks the calling thread, which is why it is
    /// unavailable from an async context (it can strand a cooperative-pool
    /// thread). Do the blocking wait on a global queue and suspend the caller
    /// instead, so the semaphore-based rendezvous these tests need still works
    /// from inside a `Task`.
    func waitAsync(timeout: DispatchTime) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.wait(timeout: timeout))
            }
        }
    }
}
