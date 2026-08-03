import Foundation

// MARK: - Named locks: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`src/client/api/locksApi.ts`, issue #1518) field-for-field, including
// optionality. Timestamps stay ISO-8601 `String`s — exactly what JS exposes.
//
// TypeScript models the four result shapes as discriminated unions
// (`{acquired:true, handle}` | `{acquired:false, …}`). Swift decodes them as
// structs with a discriminator flag plus optional payload fields, the same way
// the rest of this client decodes server unions: an unknown or newly added
// field can never fail the decode, and callers branch on the flag (or use the
// convenience accessors below).

// MARK: Handles

/// The token returned by a successful acquire. `release` and `renew` require
/// its opaque `handleId` — that is what enforces holder identity. Mirrors the
/// fields JS `LockHandle` exposes today; any fencing token the server mints is
/// not surfaced here yet (parity follow-up: #2005).
public struct LockHandle: Codable, Sendable, Equatable {
    /// The caller-chosen lock key this handle holds.
    public let key: String
    /// Opaque holder token. Required by `release` / `renew`; treat as opaque.
    public let handleId: String
    /// ISO-8601 timestamp when the lease expires if not renewed or released.
    public let leaseExpiresAt: String

    public init(key: String, handleId: String, leaseExpiresAt: String) {
        self.key = key
        self.handleId = handleId
        self.leaseExpiresAt = leaseExpiresAt
    }
}

// MARK: Acquire

/// The "someone else holds it" arm of an acquire response. Mirrors JS
/// `LockContention`. Every holder field is nullable server-side.
public struct LockContention: Sendable, Equatable {
    public let heldBy: String?
    public let holderKind: String?
    public let leaseExpiresAt: String?
    /// Suggested delay before retrying, in milliseconds.
    public let retryAfterMs: Int

    public init(
        heldBy: String? = nil,
        holderKind: String? = nil,
        leaseExpiresAt: String? = nil,
        retryAfterMs: Int
    ) {
        self.heldBy = heldBy
        self.holderKind = holderKind
        self.leaseExpiresAt = leaseExpiresAt
        self.retryAfterMs = retryAfterMs
    }
}

/// Raw response of `POST /locks/acquire` — JS `AcquireResponse`.
///
/// `acquired == true` carries `handle`; `acquired == false` carries the
/// contention fields. Most callers use `LocksAPI.tryAcquire` / `acquire`
/// instead of decoding this directly.
public struct LockAcquireResponse: Decodable, Sendable, Equatable {
    public let acquired: Bool
    /// Present when `acquired == true`.
    public let handle: LockHandle?
    public let heldBy: String?
    public let holderKind: String?
    public let leaseExpiresAt: String?
    /// Present when `acquired == false`; suggested retry delay in ms.
    public let retryAfterMs: Int?

    /// The contention detail when the key was held, `nil` when acquired.
    public var contention: LockContention? {
        guard !acquired else { return nil }
        return LockContention(
            heldBy: heldBy,
            holderKind: holderKind,
            leaseExpiresAt: leaseExpiresAt,
            retryAfterMs: retryAfterMs ?? LocksAPI.defaultRetryAfterMs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case acquired, handle, heldBy, holderKind, leaseExpiresAt, retryAfterMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acquired = try c.decodeIfPresent(Bool.self, forKey: .acquired) ?? false
        handle = try c.decodeIfPresent(LockHandle.self, forKey: .handle)
        heldBy = try c.decodeIfPresent(String.self, forKey: .heldBy)
        holderKind = try c.decodeIfPresent(String.self, forKey: .holderKind)
        leaseExpiresAt = try c.decodeIfPresent(String.self, forKey: .leaseExpiresAt)
        // Decoded through `Double` on purpose: the server computes this from a
        // date difference, so it is always integral, but a JSON number that
        // arrives as `250.0` would hard-fail a direct `Int` decode and take the
        // whole acquire down with it.
        retryAfterMs = try c.decodeIfPresent(Double.self, forKey: .retryAfterMs).map {
            Int($0.rounded())
        }
    }

    public init(
        acquired: Bool,
        handle: LockHandle? = nil,
        heldBy: String? = nil,
        holderKind: String? = nil,
        leaseExpiresAt: String? = nil,
        retryAfterMs: Int? = nil
    ) {
        self.acquired = acquired
        self.handle = handle
        self.heldBy = heldBy
        self.holderKind = holderKind
        self.leaseExpiresAt = leaseExpiresAt
        self.retryAfterMs = retryAfterMs
    }
}

// MARK: Release / renew

/// Result of `POST /locks/release` — JS `ReleaseResult`.
///
/// A release that did not happen is **not** an error: `released == false` with
/// `reason == "not_holder"` (someone else holds the key now) or `"not_held"`
/// (the key is already free). `reason` is kept as a `String` rather than a
/// closed enum so a future server-side reason cannot fail the decode.
public struct LockReleaseResult: Decodable, Sendable, Equatable {
    public let released: Bool
    /// `"not_holder"` or `"not_held"` when `released == false`.
    public let reason: String?

    public init(released: Bool, reason: String? = nil) {
        self.released = released
        self.reason = reason
    }
}

/// Result of `POST /locks/renew` — JS `RenewResult`.
///
/// `renewed == false` with `reason == "lease_lost"` means the handle no longer
/// holds the key (it expired or was taken over); the caller must stop treating
/// its work as exclusive and re-acquire.
public struct LockRenewResult: Decodable, Sendable, Equatable {
    public let renewed: Bool
    /// The new expiry when `renewed == true`.
    public let leaseExpiresAt: String?
    /// `"lease_lost"` when `renewed == false`.
    public let reason: String?

    public init(renewed: Bool, leaseExpiresAt: String? = nil, reason: String? = nil) {
        self.renewed = renewed
        self.leaseExpiresAt = leaseExpiresAt
        self.reason = reason
    }
}

// MARK: Status / list

/// Result of `POST /locks/status` — JS `LockStatus`. All holder fields are
/// `nil` when `held == false` (free or lease-expired).
public struct LockStatus: Decodable, Sendable, Equatable {
    public let held: Bool
    public let heldBy: String?
    public let holderKind: String?
    /// `WorkflowRun.runId` when the holder is a workflow; `nil` for user holds.
    public let holderRunId: String?
    public let acquiredAt: String?
    public let leaseExpiresAt: String?

    public init(
        held: Bool,
        heldBy: String? = nil,
        holderKind: String? = nil,
        holderRunId: String? = nil,
        acquiredAt: String? = nil,
        leaseExpiresAt: String? = nil
    ) {
        self.held = held
        self.heldBy = heldBy
        self.holderKind = holderKind
        self.holderRunId = holderRunId
        self.acquiredAt = acquiredAt
        self.leaseExpiresAt = leaseExpiresAt
    }
}

/// One row of `GET /locks` — JS `LockListEntry`.
public struct LockListEntry: Decodable, Sendable, Equatable {
    public let key: String
    public let heldBy: String?
    public let holderKind: String?
    public let holderRunId: String?
    public let acquiredAt: String?
    public let leaseExpiresAt: String?

    public init(
        key: String,
        heldBy: String? = nil,
        holderKind: String? = nil,
        holderRunId: String? = nil,
        acquiredAt: String? = nil,
        leaseExpiresAt: String? = nil
    ) {
        self.key = key
        self.heldBy = heldBy
        self.holderKind = holderKind
        self.holderRunId = holderRunId
        self.acquiredAt = acquiredAt
        self.leaseExpiresAt = leaseExpiresAt
    }
}

/// Result of `GET /locks` (admin) — JS `LockListResult`.
public struct LockListResult: Decodable, Sendable, Equatable {
    public let locks: [LockListEntry]

    public init(locks: [LockListEntry]) {
        self.locks = locks
    }
}

// MARK: - Request bodies

/// `POST /locks/acquire` body. Encodable so the request never goes through an
/// untyped `[String: Any]` dictionary.
struct LockAcquireRequest: Encodable {
    let key: String
    let ttlMs: Int
}

/// The `{ handleId }` object `release` / `renew` nest under `handle`.
struct LockHandleRef: Encodable {
    let handleId: String
}

/// `POST /locks/release` body.
struct LockReleaseRequest: Encodable {
    let key: String
    let handle: LockHandleRef
}

/// `POST /locks/renew` body.
struct LockRenewRequest: Encodable {
    let key: String
    let handle: LockHandleRef
    let ttlMs: Int
}

/// `POST /locks/status` body.
struct LockStatusRequest: Encodable {
    let key: String
}
