import Foundation

// MARK: - Notifications: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/notificationsApi.d.ts` / `src/client/api/notificationsApi.ts`)
// field-for-field, including optionality. Timestamps stay ISO-8601
// `String`s — exactly what JS exposes.
//
// Outcome status fields (send results, per-token attempts) are kept as
// `String` rather than closed enums: they are server-authored reports that
// may gain values, and the "deliver rather than drop" rule (same reasoning
// as `InvitationEvent.action`) means an unknown status must not fail the
// decode. The known values are documented on each field.

// MARK: Inbox rows

/// A durable in-app notification inbox row. Mirrors JS `NotificationInfo`.
public struct NotificationInfo: Decodable, Sendable, Equatable {
    public let notificationId: String
    public let title: String
    public let body: String
    public let iconUrl: String?
    public let deepLink: String?
    public let read: Bool
    public let readAt: String?
    public let expiresAt: String?
    /// Where the send came from, e.g. `workflowKey:runKey` or `api:<userId>`.
    public let sourceRef: String?
    public let createdAt: String

    public init(
        notificationId: String,
        title: String,
        body: String,
        iconUrl: String? = nil,
        deepLink: String? = nil,
        read: Bool,
        readAt: String? = nil,
        expiresAt: String? = nil,
        sourceRef: String? = nil,
        createdAt: String
    ) {
        self.notificationId = notificationId
        self.title = title
        self.body = body
        self.iconUrl = iconUrl
        self.deepLink = deepLink
        self.read = read
        self.readAt = readAt
        self.expiresAt = expiresAt
        self.sourceRef = sourceRef
        self.createdAt = createdAt
    }
}

/// A page of inbox rows plus the caller's unread count. Mirrors JS
/// `NotificationListResult`.
public struct NotificationListResult: Decodable, Sendable, Equatable {
    public let items: [NotificationInfo]
    /// Unread count for the caller (bounded — capped for very large inboxes).
    public let unreadCount: Int
    public let cursor: String?

    public init(items: [NotificationInfo], unreadCount: Int, cursor: String? = nil) {
        self.items = items
        self.unreadCount = unreadCount
        self.cursor = cursor
    }
}

/// Result of `notifications.unreadCount()` — `{ unreadCount }`.
public struct NotificationUnreadCountResult: Decodable, Sendable, Equatable {
    public let unreadCount: Int

    public init(unreadCount: Int) {
        self.unreadCount = unreadCount
    }
}

/// Result of `notifications.markAllRead()` — `{ updated }`.
public struct NotificationMarkAllReadResult: Decodable, Sendable, Equatable {
    /// How many rows transitioned from unread to read.
    public let updated: Int

    public init(updated: Int) {
        self.updated = updated
    }
}

// MARK: Send

/// Parameters for `notifications.send`. Mirrors JS `SendNotificationParams`.
/// `title`, `body`, and `target.userId` are required.
public struct SendNotificationParams: Encodable, Sendable {
    /// Recipient selector. Currently `{ userId }` only, matching JS.
    public struct Target: Encodable, Sendable {
        public var userId: String

        public init(userId: String) {
            self.userId = userId
        }
    }

    public var title: String
    public var body: String
    public var target: Target
    /// Channel list; the server defaults to `["in-app"]` when omitted.
    public var channels: [String]?
    public var iconUrl: String?
    public var deepLink: String?
    /// ISO date string; the inbox row expires (and is auto-deleted) after this.
    public var expiresAt: String?
    /// Recorded on the row for tracing; the server defaults to `api:<caller>`.
    public var sourceRef: String?
    /// Dedupe key: a repeat send with the same key returns the prior outcome.
    public var idempotencyKey: String?

    public init(
        title: String,
        body: String,
        target: Target,
        channels: [String]? = nil,
        iconUrl: String? = nil,
        deepLink: String? = nil,
        expiresAt: String? = nil,
        sourceRef: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.title = title
        self.body = body
        self.target = target
        self.channels = channels
        self.iconUrl = iconUrl
        self.deepLink = deepLink
        self.expiresAt = expiresAt
        self.sourceRef = sourceRef
        self.idempotencyKey = idempotencyKey
    }
}

/// Per-device-token outcome inside a push channel attempt. Mirrors JS
/// `NotificationTokenAttempt`.
public struct NotificationTokenAttempt: Decodable, Sendable, Equatable {
    /// Last 8 chars of the device token — never the full token.
    public let tokenSuffix: String
    /// One of `"delivered"`, `"failed"`, `"invalidated"`. Kept as `String`
    /// for forward-compatibility.
    public let status: String
    public let httpStatus: Int?
    public let reason: String?
    public let retryable: Bool?

    public init(
        tokenSuffix: String,
        status: String,
        httpStatus: Int? = nil,
        reason: String? = nil,
        retryable: Bool? = nil
    ) {
        self.tokenSuffix = tokenSuffix
        self.status = status
        self.httpStatus = httpStatus
        self.reason = reason
        self.retryable = retryable
    }
}

/// Per-channel outcome of a send. Mirrors JS `NotificationSendResult`.
public struct NotificationSendResult: Decodable, Sendable, Equatable {
    public let channel: String
    /// One of `"delivered"`, `"failed"`, `"skipped"`, `"invalidated"`
    /// (`"invalidated"`: every push token for the recipient was dead and
    /// evicted). Kept as `String` for forward-compatibility.
    public let status: String
    /// in-app channel: the durable inbox row id.
    public let notificationId: String?
    /// push: per-token tallies (one user can hold several device tokens).
    public let delivered: Int?
    public let failed: Int?
    public let invalidated: Int?
    /// push: per-token detail.
    public let tokenAttempts: [NotificationTokenAttempt]?
    public let skipReason: String?
    public let httpStatus: Int?
    public let error: String?
    /// Whether a retry could plausibly succeed; set when status is `"failed"`.
    public let retryable: Bool?

    public init(
        channel: String,
        status: String,
        notificationId: String? = nil,
        delivered: Int? = nil,
        failed: Int? = nil,
        invalidated: Int? = nil,
        tokenAttempts: [NotificationTokenAttempt]? = nil,
        skipReason: String? = nil,
        httpStatus: Int? = nil,
        error: String? = nil,
        retryable: Bool? = nil
    ) {
        self.channel = channel
        self.status = status
        self.notificationId = notificationId
        self.delivered = delivered
        self.failed = failed
        self.invalidated = invalidated
        self.tokenAttempts = tokenAttempts
        self.skipReason = skipReason
        self.httpStatus = httpStatus
        self.error = error
        self.retryable = retryable
    }
}

/// Result of `notifications.send`. Mirrors the JS inline return
/// `{ results, deduplicated?, deduplicatedChannels? }`.
public struct NotificationSendResponse: Decodable, Sendable, Equatable {
    public let results: [NotificationSendResult]
    /// True when the idempotency key matched a prior send and nothing was
    /// re-sent.
    public let deduplicated: Bool?
    /// Channels served from a prior send under the idempotency key instead of
    /// re-sent.
    public let deduplicatedChannels: [String]?

    public init(
        results: [NotificationSendResult],
        deduplicated: Bool? = nil,
        deduplicatedChannels: [String]? = nil
    ) {
        self.results = results
        self.deduplicated = deduplicated
        self.deduplicatedChannels = deduplicatedChannels
    }
}

// MARK: Push devices

/// Platform of a registered push device. Mirrors the JS
/// `"ios" | "macos" | "android"` union. A closed set the caller picks from,
/// so a compile-time-checked enum (like `AvatarContentType`) fits.
public enum PushPlatform: String, Codable, Sendable {
    case ios
    case macos
    case android
}

/// APNs delivery environment. Mirrors the JS `"sandbox" | "production"`
/// union. FCM has no sandbox — use `.production`.
public enum PushEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// A registered push device (token echoed as a suffix only). Mirrors JS
/// `PushDeviceInfo`.
public struct PushDeviceInfo: Decodable, Sendable, Equatable {
    public let tokenId: String
    public let tokenSuffix: String?
    public let platform: PushPlatform
    public let environment: PushEnvironment
    public let bundleId: String?
    public let deviceName: String?
    public let appVersion: String?
    public let lastSeenAt: String?
    public let createdAt: String

    public init(
        tokenId: String,
        tokenSuffix: String? = nil,
        platform: PushPlatform,
        environment: PushEnvironment,
        bundleId: String? = nil,
        deviceName: String? = nil,
        appVersion: String? = nil,
        lastSeenAt: String? = nil,
        createdAt: String
    ) {
        self.tokenId = tokenId
        self.tokenSuffix = tokenSuffix
        self.platform = platform
        self.environment = environment
        self.bundleId = bundleId
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
    }
}

/// Parameters for `notifications.registerDevice`. Mirrors JS
/// `RegisterPushDeviceParams`.
public struct RegisterPushDeviceParams: Encodable, Sendable {
    /// APNs hex device token or FCM registration token.
    public var token: String
    public var platform: PushPlatform
    /// APNs sandbox vs production; FCM has no sandbox — use `.production`.
    public var environment: PushEnvironment
    public var bundleId: String?
    public var deviceName: String?
    public var appVersion: String?

    public init(
        token: String,
        platform: PushPlatform,
        environment: PushEnvironment,
        bundleId: String? = nil,
        deviceName: String? = nil,
        appVersion: String? = nil
    ) {
        self.token = token
        self.platform = platform
        self.environment = environment
        self.bundleId = bundleId
        self.deviceName = deviceName
        self.appVersion = appVersion
    }
}

/// A page of registered push devices. Mirrors the JS inline return
/// `{ items }` from `notifications.listDevices`.
public struct PushDeviceListResult: Decodable, Sendable, Equatable {
    public let items: [PushDeviceInfo]

    public init(items: [PushDeviceInfo]) {
        self.items = items
    }
}

/// Result of `notifications.unregisterDevice` — `{ deleted }`.
public struct UnregisterPushDeviceResult: Decodable, Sendable, Equatable {
    public let deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }
}
