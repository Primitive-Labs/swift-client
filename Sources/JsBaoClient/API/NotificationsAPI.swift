import Foundation

// MARK: - NotificationsAPI

/// Sub-API for the notification inbox (`client.notifications.*`). Mirrors the
/// JS client's `NotificationsAPI` (`src/client/api/notificationsApi.ts`)
/// method-for-method.
///
/// Inbox reads/writes act on the signed-in user's own notifications.
/// `send()` requires app admin permission. Live in-app notifications arrive
/// as the `.notification` client event
/// (`for await e in client.stream(for: NotificationEvent.self)`) — the
/// durable inbox row is the source of truth, fetched via `list()`.
public final class NotificationsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Inbox

    /// List the caller's notifications, newest first.
    public func list(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> NotificationListResult {
        var query = URLQuery()
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        return try await transport.request(method: .get, path: "/notifications\(query.queryString)")
    }

    /// Count the caller's unread notifications.
    public func unreadCount() async throws -> NotificationUnreadCountResult {
        try await transport.request(method: .get, path: "/notifications/unread-count")
    }

    /// Mark one of the caller's notifications as read.
    public func markRead(notificationId: String) async throws -> NotificationInfo {
        let escaped = URLEncoding.encodeComponent(notificationId)
        return try await transport.request(
            method: .patch,
            path: "/notifications/\(escaped)/read",
            body: EmptyObjectBody()
        )
    }

    /// Mark all of the caller's notifications as read.
    public func markAllRead() async throws -> NotificationMarkAllReadResult {
        try await transport.request(
            method: .post,
            path: "/notifications/read-all",
            body: EmptyObjectBody()
        )
    }

    /// Send a notification to an app user (requires app admin permission).
    public func send(params: SendNotificationParams) async throws -> NotificationSendResponse {
        try await transport.request(method: .post, path: "/notifications/send", body: params)
    }

    // MARK: - Push devices

    /// Register (upsert) the calling user's device push token.
    public func registerDevice(params: RegisterPushDeviceParams) async throws -> PushDeviceInfo {
        try await transport.request(method: .post, path: "/me/push-tokens", body: params)
    }

    /// List the calling user's registered push devices.
    public func listDevices() async throws -> PushDeviceListResult {
        try await transport.request(method: .get, path: "/me/push-tokens")
    }

    /// Unregister one of the calling user's device push tokens (e.g. on logout).
    public func unregisterDevice(token: String) async throws -> UnregisterPushDeviceResult {
        let escaped = URLEncoding.encodeComponent(token)
        return try await transport.request(method: .delete, path: "/me/push-tokens/\(escaped)")
    }
}

// MARK: - Request shims

/// The `{}` request body the mark-read endpoints have always sent (previously
/// an empty untyped dictionary literal). A typed `Encodable` keeps the wire
/// bytes identical without going through `Any`.
private struct EmptyObjectBody: Encodable, Sendable {}
