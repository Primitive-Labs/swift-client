import Foundation

// MARK: - AnalyticsEventInput

/// Typed input for `client.analytics.logEvent(_:)`. Mirrors js-bao's
/// `AnalyticsEventInput` (`src/client/internal/analyticsQueue.ts`) field
/// for field. Keys are deliberately snake_case to match the wire schema
/// the queue and server expect.
///
/// `user_ulid` is optional here even though the JS interface marks it
/// required: the `AnalyticsQueue` fills it from `getUserId` (falling back
/// to `unauthenticatedUser`) when it's absent, so callers normally leave
/// it nil and write `AnalyticsEventInput(action: "click", feature: "editor")`.
public struct AnalyticsEventInput: Encodable, Sendable {
    public var action: String
    public var feature: String?
    public var route: String?
    public var plan: String?
    public var tenant_id: String?
    public var user_ulid: String?
    public var device_type: String?
    public var os_name: String?
    public var os_version: String?
    public var browser_name: String?
    public var browser_version: String?
    public var app_version: String?
    public var context_json: JSONValue?
    public var user_created_at_epoch_s: Int?

    /// Sentinel user id stamped on events logged before authentication.
    /// Mirrors JS `ANALYTICS_UNAUTHENTICATED_USER` and the value the
    /// `AnalyticsQueue` already uses internally.
    public static let unauthenticatedUser = "UNAUTHENTICATED"

    public init(
        action: String,
        feature: String? = nil,
        route: String? = nil,
        plan: String? = nil,
        tenant_id: String? = nil,
        user_ulid: String? = nil,
        device_type: String? = nil,
        os_name: String? = nil,
        os_version: String? = nil,
        browser_name: String? = nil,
        browser_version: String? = nil,
        app_version: String? = nil,
        context_json: JSONValue? = nil,
        user_created_at_epoch_s: Int? = nil
    ) {
        self.action = action
        self.feature = feature
        self.route = route
        self.plan = plan
        self.tenant_id = tenant_id
        self.user_ulid = user_ulid
        self.device_type = device_type
        self.os_name = os_name
        self.os_version = os_version
        self.browser_name = browser_name
        self.browser_version = browser_version
        self.app_version = app_version
        self.context_json = context_json
        self.user_created_at_epoch_s = user_created_at_epoch_s
    }

    /// The event as the typed `[String: JSONValue]` row the `AnalyticsQueue`
    /// buffers since #1993 Phase D3. Nil fields are dropped (so the queue's
    /// defaulting and override logic still applies) and keys stay snake_case
    /// exactly as the queue expects.
    ///
    /// This is the direct path — no `Any` graph in the middle — so the typed
    /// `client.analytics.logEvent` surface never pays for a conversion the
    /// untyped one needs.
    public func asJSONObject() -> [String: JSONValue] {
        var row: [String: JSONValue] = ["action": .string(action)]
        if let feature { row["feature"] = .string(feature) }
        if let route { row["route"] = .string(route) }
        if let plan { row["plan"] = .string(plan) }
        if let tenant_id { row["tenant_id"] = .string(tenant_id) }
        if let user_ulid { row["user_ulid"] = .string(user_ulid) }
        if let device_type { row["device_type"] = .string(device_type) }
        if let os_name { row["os_name"] = .string(os_name) }
        if let os_version { row["os_version"] = .string(os_version) }
        if let browser_name { row["browser_name"] = .string(browser_name) }
        if let browser_version { row["browser_version"] = .string(browser_version) }
        if let app_version { row["app_version"] = .string(app_version) }
        if let user_created_at_epoch_s {
            row["user_created_at_epoch_s"] = .number(Double(user_created_at_epoch_s))
        }
        if let context_json { row["context_json"] = context_json }
        return row
    }

    /// Bridge to the untyped `[String: Any]` graph. Nil fields are dropped (so
    /// the queue's defaulting and override logic still applies), and
    /// `context_json` is lowered to its underlying JSON `Any` value. Keys stay
    /// snake_case exactly as the queue expects.
    ///
    /// The analytics queue itself takes `asJSONObject()` now; this stays for
    /// callers that still speak the `Any` graph.
    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = ["action": action]
        if let feature { dict["feature"] = feature }
        if let route { dict["route"] = route }
        if let plan { dict["plan"] = plan }
        if let tenant_id { dict["tenant_id"] = tenant_id }
        if let user_ulid { dict["user_ulid"] = user_ulid }
        if let device_type { dict["device_type"] = device_type }
        if let os_name { dict["os_name"] = os_name }
        if let os_version { dict["os_version"] = os_version }
        if let browser_name { dict["browser_name"] = browser_name }
        if let browser_version { dict["browser_version"] = browser_version }
        if let app_version { dict["app_version"] = app_version }
        if let user_created_at_epoch_s { dict["user_created_at_epoch_s"] = user_created_at_epoch_s }
        if let context_json { dict["context_json"] = context_json.toAny() }
        return dict
    }
}

// MARK: - JSONValue → Any lowering

public extension JSONValue {
    /// Lower a `JSONValue` into the loosely-typed `Any` graph that
    /// `JSONSerialization` speaks — the inverse of ``JSONValue/init(jsonAny:subject:)``.
    /// `.null` becomes `NSNull` so it survives serialization.
    ///
    /// Use this at a boundary that has to hand JSON to an API taking `Any`
    /// (`JSONSerialization`, a debug/inspector payload). Inside the client,
    /// prefer passing the `JSONValue` itself.
    func toAny() -> Any {
        switch self {
        case let .string(s): return s
        case let .number(n): return n
        case let .bool(b): return b
        case let .object(o): return o.mapValues { $0.toAny() }
        case let .array(a): return a.map { $0.toAny() }
        case .null: return NSNull()
        }
    }
}
