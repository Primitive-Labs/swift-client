import Foundation

/// The `openDocument` waits that are currently in flight, so a frame the
/// router handles can fail one of them.
///
/// `openDocument`'s network wait settles on a `SyncEvent` or on its own
/// availability timeout. That is right for every failure the server reports by
/// staying quiet, but wrong for one it reports and then hangs up on: the
/// platform's `DOCUMENT_FORMAT_UNSUPPORTED` refusal is its last word for the
/// document, so a wait left to time out would report `NETWORK_TIMEOUT` half a
/// minute later against a server that answered immediately and precisely.
///
/// Registration is per WAIT, not per document: two opens of one document each
/// get their own entry and each is failed.
final class AwaitingOpenRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var waits: [UUID: (documentId: String, fail: (JsBaoError) -> Void)] = [:]
    private var deadlines: [UUID: (documentId: String, deadline: AvailabilityDeadline)] = [:]

    /// Register a wait. The returned token withdraws it — call it from the
    /// wait's own settle path, whichever way it settles.
    func register(
        documentId: String,
        fail: @escaping (JsBaoError) -> Void
    ) -> UUID {
        let token = UUID()
        lock.withLock { waits[token] = (documentId, fail) }
        return token
    }

    func withdraw(_ token: UUID) {
        lock.withLock {
            _ = waits.removeValue(forKey: token)
            _ = deadlines.removeValue(forKey: token)
        }
    }

    /// Attach the availability budget of the wait `token` registered, so
    /// progress on its document starts the budget again (#4609).
    func attach(_ deadline: AvailabilityDeadline, to token: UUID) {
        lock.withLock {
            guard let documentId = waits[token]?.documentId else { return }
            deadlines[token] = (documentId, deadline)
        }
    }

    /// `documentId`'s first sync made progress: every wait on it gets a whole
    /// budget from now.
    func progress(documentId: String) {
        let extended = lock.withLock { deadlines.values.filter { $0.documentId == documentId }.map(\.deadline) }
        for deadline in extended { deadline.extend() }
    }

    /// Fail every wait on `documentId`. The handlers run OUTSIDE the lock:
    /// each resumes a continuation, and the caller's own settle path
    /// re-enters `withdraw`.
    func fail(documentId: String, error: JsBaoError) {
        let doomed: [(JsBaoError) -> Void] = lock.withLock {
            let matching = waits.filter { $0.value.documentId == documentId }
            for key in matching.keys { waits.removeValue(forKey: key) }
            return matching.values.map { $0.fail }
        }
        for fail in doomed { fail(error) }
    }
}

/// An open's availability budget, which bounds its wait WITHOUT progress
/// (#4609): it runs from the start of the wait, and again from each progress
/// report — a `building` answer, a catch-up page, a segment or load chunk.
/// Measured on a monotonic clock, so a wall-clock correction neither cuts the
/// budget short nor stretches it.
final class AvailabilityDeadline: @unchecked Sendable {

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let budget: Duration
    private var lastProgress: ContinuousClock.Instant

    init(budget: TimeInterval) {
        self.budget = .seconds(max(0, budget))
        self.lastProgress = clock.now
    }

    /// Progress: a whole budget from now.
    func extend() {
        lock.withLock { lastProgress = clock.now }
    }

    /// Seconds until the budget runs out; zero or less once it has.
    var remaining: TimeInterval {
        let left = lock.withLock { lastProgress.advanced(by: budget) - clock.now }
        let parts = left.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// A refusal that may arrive before the wait that has to hear it (#3764, D9).
///
/// `openDocument` suspends inside `wsManager.send` while its handshake goes out,
/// and the room can answer before the availability wait exists. The registry
/// notifies only what is registered and retains nothing, so the callback is
/// registered before the send and points here: this holds the answer until the
/// wait attaches, and hands it over at once when it does.
final class EarlyRefusal: @unchecked Sendable {

    private let lock = NSLock()
    private var error: JsBaoError?
    private var deliver: ((JsBaoError) -> Void)?

    /// The refusal arrived. Delivered now when a wait is attached, kept if not.
    func fail(_ error: JsBaoError) {
        let sink: ((JsBaoError) -> Void)? = lock.withLock {
            if let deliver = self.deliver { return deliver }
            self.error = error
            return nil
        }
        sink?(error)
    }

    /// The wait exists. Answers a refusal that has already arrived.
    func attach(_ deliver: @escaping (JsBaoError) -> Void) {
        let pending: JsBaoError? = lock.withLock {
            self.deliver = deliver
            let held = self.error
            self.error = nil
            return held
        }
        if let pending { deliver(pending) }
    }
}
