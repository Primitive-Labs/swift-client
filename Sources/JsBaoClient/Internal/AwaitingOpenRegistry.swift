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
