import XCTest
@testable import JsBaoClient

/// Live tests for the named lock API (`client.locks.*`) against the local dev
/// server — the Swift mirror of the JS client's
/// `tests/client/js-bao-client-locks-blocking.test.ts` (#1518 / #1574).
///
/// Everything runs through the app owner's token on a single client: the
/// server treats a re-acquire by the current holder as **contention**, not
/// re-entrancy (the 2026-07-14 decision in `lock-service.ts`), so one client is
/// enough to exercise contention, release-ownership, and the blocking poll.
final class LocksTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-locks")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    /// Unique per run so parallel/repeat runs never contend with each other.
    private func uniqueKey(_ label: String) -> String {
        "\(label):\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Acquire / contention (behaviors 1, 2)

    func testTryAcquireReturnsHandleOnFreeKeyAndNilWhenHeld() async throws {
        let key = uniqueKey("try")

        let handle = try await client.locks.tryAcquire(key: key, ttl: 60)
        let acquired = try XCTUnwrap(handle, "A free key should be acquirable")
        XCTAssertEqual(acquired.key, key)
        XCTAssertFalse(acquired.handleId.isEmpty, "Acquire must return an opaque handleId")
        XCTAssertFalse(acquired.leaseExpiresAt.isEmpty, "Acquire must return a lease expiry")

        // Contention: a live lease blocks the next acquire — even for the same
        // caller, which the server answers with `acquired: false` rather than
        // re-entering the lock.
        let second = try await client.locks.tryAcquire(key: key, ttl: 60)
        XCTAssertNil(second, "A held key must not be re-acquired, not even by the holder")

        let released = try await client.locks.release(acquired)
        XCTAssertTrue(released.released)
    }

    // MARK: - Release ownership (behavior 3)

    func testReleaseRequiresTheHoldingHandle() async throws {
        let key = uniqueKey("release-ownership")
        let acquiredHandle = try await client.locks.tryAcquire(key: key, ttl: 60)
        let handle = try XCTUnwrap(acquiredHandle)

        // A wrong/stale handleId does not free someone else's lock — and it is
        // reported, not thrown.
        let bogus = LockHandle(
            key: key,
            handleId: "not-the-holder-\(UUID().uuidString)",
            leaseExpiresAt: handle.leaseExpiresAt
        )
        let refused = try await client.locks.release(bogus)
        XCTAssertFalse(refused.released, "A non-holder must not be able to release the key")
        XCTAssertEqual(refused.reason, "not_holder")

        // The real holder still holds it.
        let stillHeld = try await client.locks.status(key: key)
        XCTAssertTrue(stillHeld.held)

        let released = try await client.locks.release(handle)
        XCTAssertTrue(released.released)

        // Releasing a free key reports `not_held` rather than failing.
        let again = try await client.locks.release(handle)
        XCTAssertFalse(again.released)
        XCTAssertEqual(again.reason, "not_held")
    }

    // MARK: - Renew + status + list (behaviors 4, 5, 6)

    func testRenewExtendsTheLeaseAndStatusListReflectTheHeldLock() async throws {
        let key = uniqueKey("renew-status")
        let handle = try await client.locks.acquire(key: key, ttl: 1, timeout: 3)

        let renewed = try await client.locks.renew(handle, ttl: 60)
        XCTAssertTrue(renewed.renewed)
        let before = try XCTUnwrap(isoDate(handle.leaseExpiresAt))
        let renewedExpiry = try XCTUnwrap(renewed.leaseExpiresAt)
        let after = try XCTUnwrap(isoDate(renewedExpiry))
        XCTAssertGreaterThan(after, before, "renew must push the lease expiry out")

        let status = try await client.locks.status(key: key)
        XCTAssertTrue(status.held)
        XCTAssertNotNil(status.heldBy)
        XCTAssertEqual(status.holderKind, "user")

        // `list()` is admin-only; the app owner's token qualifies.
        let listed = try await client.locks.list()
        XCTAssertTrue(listed.locks.contains { $0.key == key }, "list() must include a held key")

        let released = try await client.locks.release(handle)
        XCTAssertTrue(released.released)

        let afterStatus = try await client.locks.status(key: key)
        XCTAssertFalse(afterStatus.held, "status must report a released key as free")
    }

    func testRenewOfALostLeaseReportsLeaseLost() async throws {
        let key = uniqueKey("renew-lost")
        let acquiredHandle = try await client.locks.tryAcquire(key: key, ttl: 60)
        let handle = try XCTUnwrap(acquiredHandle)
        _ = try await client.locks.release(handle)

        let renewed = try await client.locks.renew(handle, ttl: 60)
        XCTAssertFalse(renewed.renewed, "A released handle can no longer renew")
        XCTAssertEqual(renewed.reason, "lease_lost")
    }

    // MARK: - Blocking acquire (behaviors 7, 8)

    func testBlockingAcquireResolvesOnceTheHolderReleases() async throws {
        let key = uniqueKey("block-release")
        let heldHandle = try await client.locks.tryAcquire(key: key, ttl: 60)
        let held = try XCTUnwrap(heldHandle)

        // Release from a detached task while the blocking acquire is polling.
        let releaser = Task { [client] in
            try? await Task.sleep(nanoseconds: 800 * 1_000_000)
            _ = try? await client?.locks.release(held)
        }
        defer { releaser.cancel() }

        let start = Date()
        let handle = try await client.locks.acquire(key: key, ttl: 60, timeout: 15)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(handle.key, key)
        XCTAssertNotEqual(handle.handleId, held.handleId, "A new acquire mints a new handle")
        XCTAssertGreaterThanOrEqual(
            elapsed, 0.7,
            "acquire must have waited for the release rather than returning immediately"
        )

        _ = try await client.locks.release(handle)
    }

    func testBlockingAcquireThrowsLockTimeoutWhenTheHolderNeverReleases() async throws {
        let key = uniqueKey("block-timeout")
        let heldHandle = try await client.locks.tryAcquire(key: key, ttl: 60)
        let held = try XCTUnwrap(heldHandle)

        do {
            _ = try await client.locks.acquire(key: key, ttl: 60, timeout: 0.9)
            XCTFail("Blocking acquire on a permanently held key must time out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .lockTimeout)
            XCTAssertEqual(error.details?["key"], .string(key))
            XCTAssertEqual(error.details?["timeoutMs"], .number(900))
        }

        _ = try await client.locks.release(held)
    }

    /// `timeout` became a `TimeInterval` in #2367, so `.infinity` is
    /// expressible for the first time and means "wait indefinitely". The poll
    /// loop converts its remaining time to `Int` milliseconds on every
    /// iteration, and it only reaches that conversion when the key is
    /// contended — so this holds the key long enough to force at least one
    /// poll, then releases. Before the fix this terminated the test process
    /// (`Double value cannot be converted to Int because it is either infinite
    /// or NaN`) rather than failing.
    func testBlockingAcquireWithAnInfiniteTimeoutPollsInsteadOfTrapping() async throws {
        let key = uniqueKey("block-infinite")
        let heldHandle = try await client.locks.tryAcquire(key: key, ttl: 60)
        let held = try XCTUnwrap(heldHandle)

        let releaser = Task { [client] in
            try? await Task.sleep(nanoseconds: 800 * 1_000_000)
            _ = try? await client?.locks.release(held)
        }
        defer { releaser.cancel() }

        let start = Date()
        let handle = try await client.locks.acquire(key: key, ttl: 60, timeout: .infinity)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(handle.key, key)
        XCTAssertGreaterThanOrEqual(
            elapsed, 0.7,
            "an infinite timeout must keep polling through contention, not return early"
        )

        _ = try await client.locks.release(handle)
    }

    // MARK: - Helpers

    private func isoDate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

