import Foundation

/// The `openDocument` waits that are currently in flight, so a frame the
/// router handles can fail one of them.
///
/// `openDocument`'s network wait settles on a `SyncEvent` or on its own
/// availability timeout. That is right for every failure the server reports by
/// staying quiet, but wrong for one it reports and then hangs up on: the room's
/// `CLIENT_UPGRADE_REQUIRED` refusal (#3436) is its last word before close
/// 4426, so a wait left to time out would report `NETWORK_TIMEOUT` half a
/// minute later against a server that answered immediately and precisely.
///
/// Registration is per WAIT, not per document: two opens of one document each
/// get their own entry and each is failed.
final class AwaitingOpenRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var waits: [UUID: (documentId: String, fail: (JsBaoError) -> Void)] = [:]

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
        lock.withLock { _ = waits.removeValue(forKey: token) }
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
