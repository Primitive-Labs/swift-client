import Foundation

/// Where a large document stands relative to its offline write window
/// (#3437, behavior 1).
///
/// Field for field the JS client's `OfflineWindowStatus`, so the two clients'
/// answers can be compared directly rather than interpreted.
public struct OfflineWindowStatus: Equatable, Sendable {
    /// Whether a local write may be accepted now.
    public let writable: Bool
    /// The sync this is measured from, or `nil` when none was ever recorded.
    public let lastSyncAt: Int?
    public let windowDays: Int
    public let windowMs: Int
    /// How far PAST the window the client is; `0` while it is inside it.
    public let overdueMs: Int
}

/// The offline write window of a large document (#3437, behavior 1).
///
/// A format-2 client writes while it is offline: the write lands in the merged
/// view at once and waits in `_pending_ops` for the reconnect that replays it
/// onto whatever epoch the room has reached. What makes that replay
/// RESOLVABLE is the sealed-overlay chain back to the epoch the op was written
/// against — and retention releases an overlay once a base covers it and it is
/// older than the window W. So a client away for longer than W is writing
/// against a past the server can no longer reconcile it with.
///
/// Past the window the document is READ-ONLY rather than a growing pile of
/// writes that will be resolved by guesswork: local writes are refused with a
/// typed error, reads keep answering out of the merged view the client already
/// holds, and a sync restores writes at once. Nothing already acknowledged is
/// touched, and a refused write leaves nothing behind — no merged row, no
/// pending op — so the refusal cannot itself become a write that replays.
///
/// The window is the server's number, the same per-app W retention prunes
/// archives by, delivered on `epoch.info` and persisted locally: the session
/// that has to enforce it is by definition the one that cannot ask.
public enum Format2OfflineWindow {

    /// The window a deployment gets when it configures nothing.
    public static let defaultOfflineWindowDays = 7

    /// The range the window is clamped to — the same 1–14 days as overlay
    /// retention, because the archive chain is exactly what an offline write
    /// is replayed across.
    public static let minOfflineWindowDays = 1
    public static let maxOfflineWindowDays = 14

    static let dayMs = 24 * 60 * 60 * 1000

    /// Read a reported window, clamped, with the default for nothing at all.
    ///
    /// Clamped rather than refused for the same reason retention clamps: the
    /// alternative to a usable number here is a client that either never goes
    /// read-only or goes read-only at once, and both are worse than a number
    /// that is merely not the one someone configured.
    ///
    /// A value that is not an integer never survives the frame decoding —
    /// `frame["offlineWindowDays"] as? Int` answers `nil` for it — so it
    /// arrives here as "the frame said nothing" and takes the default, which
    /// is edge E14's third case. The column is INTEGER: a fractional window is
    /// not representable on this client at all.
    public static func configuredOfflineWindowDays(_ raw: Int?) -> Int {
        guard let raw else { return defaultOfflineWindowDays }
        return min(maxOfflineWindowDays, max(minOfflineWindowDays, raw))
    }

    /// Decide the window from the mark the client persisted.
    ///
    /// A client with no mark is writable: the window measures time since the
    /// last sync, and treating "no mark yet" as "infinitely stale" would
    /// strand a freshly loaded document in read-only with no way out. The mark
    /// is written the first time the client hears from the server, which is
    /// before it can possibly be a week behind.
    public static func offlineWindowStatus(
        lastSyncAt: Int?,
        windowDays: Int?,
        now: Int
    ) -> OfflineWindowStatus {
        let days = configuredOfflineWindowDays(windowDays)
        let windowMs = days * dayMs
        guard let lastSyncAt else {
            return OfflineWindowStatus(
                writable: true, lastSyncAt: nil, windowDays: days,
                windowMs: windowMs, overdueMs: 0
            )
        }
        // A mark in the future (a clock that jumped back) is "just synced",
        // never a refusal: the honest failure direction here is to keep
        // accepting writes.
        let elapsed = max(0, now - lastSyncAt)
        let overdueMs = max(0, elapsed - windowMs)
        return OfflineWindowStatus(
            writable: overdueMs == 0, lastSyncAt: lastSyncAt, windowDays: days,
            windowMs: windowMs, overdueMs: overdueMs
        )
    }

    /// The typed refusal a local write past the window gets.
    ///
    /// The code is the JS client's existing `DOCUMENT_OFFLINE_WINDOW_EXPIRED`
    /// string, not a new one, so one runbook covers both clients.
    public static func expired(
        documentId: String, status: OfflineWindowStatus
    ) -> JsBaoError {
        let daysBehind = (status.windowMs + status.overdueMs) / dayMs
        var details: [String: JSONValue] = [
            "documentId": .string(documentId),
            "windowDays": .number(Double(status.windowDays)),
            "overdueMs": .number(Double(status.overdueMs)),
        ]
        details["lastSyncAt"] = status.lastSyncAt.map { .number(Double($0)) } ?? .null
        return JsBaoError(
            code: .documentOfflineWindowExpired,
            message: "Large document `\(documentId)` has not synced for "
                + "\(daysBehind) days, past its \(status.windowDays)-day offline "
                + "write window. It stays readable, and writes are accepted "
                + "again once it syncs.",
            details: details
        )
    }
}
