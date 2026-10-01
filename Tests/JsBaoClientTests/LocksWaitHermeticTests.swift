import XCTest
@testable import JsBaoClient

/// The Swift client's blocking `acquire` asks the server to wait — #3930
/// behavior 32, the Swift mirror of `tests/client/js-bao-client-locks-wait-3930.test.ts`.
///
/// `POST /locks/acquire` takes an optional `waitMs`: the server holds the
/// request while another holder has the key and answers the moment it frees,
/// so the blocking loop sends `min(remaining, 30 000)` on every poll and one
/// call replaces a poll per `retryAfterMs`. Two properties are pinned here:
///
///   - **`waitMs` is encoded only when present** (the #3562 `owner` pattern),
///     so `tryAcquire` — and any caller that names no wait — puts byte for
///     byte today's body on the wire.
///   - **Every poll of the blocking loop carries it**, never more than the
///     server's cap and never more than the time left.
///
/// Server-free (`*HermeticTests`): the recorder from `LocksAPITests` answers
/// in place of a transport. The live half is in `LocksTests.swift`.
final class LocksWaitHermeticTests: XCTestCase {

    private func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func handleJSON(handleId: String = "h1") -> [String: Any] {
        ["key": "k", "handleId": handleId, "leaseExpiresAt": "2026-01-01T00:00:00.000Z"]
    }

    private func bodies(_ recorder: LocksAPITests.CallRecorder) -> [[String: Any]] {
        recorder.calls.compactMap { $0.body as? [String: Any] }
    }

    // MARK: Request encoding

    func testAcquireRequestEncodesNoWaitKeyWhenNoneIsGiven() throws {
        let body = try encoded(LockAcquireRequest(key: "jobs:import", ttlMs: 60_000))
        XCTAssertEqual(Set(body.keys), Set(["key", "ttlMs"]))
        XCTAssertNil(body["waitMs"])
    }

    // MARK: The wire, through LocksAPI

    func testBlockingAcquireEncodesExactlyTheWaitBesideTodaysFields() async throws {
        let r = LocksAPITests.CallRecorder()
        r.respond(with: ["acquired": true, "handle": handleJSON()])
        _ = try await LocksAPI(transport: r).acquire(key: "jobs:import", ttl: 60, timeout: 5)
        let sent = try XCTUnwrap(bodies(r).first)
        XCTAssertEqual(Set(sent.keys), Set(["key", "ttlMs", "waitMs"]))
    }

    func testTryAcquireSendsNoWaitAtAll() async throws {
        let r = LocksAPITests.CallRecorder()
        r.respond(with: ["acquired": true, "handle": handleJSON()])
        _ = try await LocksAPI(transport: r).tryAcquire(key: "k", ttl: 60)
        let sent = try XCTUnwrap(bodies(r).first)
        XCTAssertEqual(Set(sent.keys), Set(["key", "ttlMs"]))
    }

    func testBlockingAcquireAsksForAtMostTheServerCapOnItsFirstPoll() async throws {
        let r = LocksAPITests.CallRecorder()
        r.respond(with: ["acquired": true, "handle": handleJSON()])
        _ = try await LocksAPI(transport: r).acquire(key: "k", ttl: 60, timeout: 45)
        let first = try XCTUnwrap(bodies(r).first)
        XCTAssertEqual(first["waitMs"] as? Int, 30_000)
    }

    func testBlockingAcquireNeverAsksForMoreThanTheTimeout() async throws {
        let r = LocksAPITests.CallRecorder()
        r.respond(with: ["acquired": true, "handle": handleJSON()])
        _ = try await LocksAPI(transport: r).acquire(key: "k", ttl: 60, timeout: 4)
        let waitMs = try XCTUnwrap(bodies(r).first?["waitMs"] as? Int)
        XCTAssertLessThanOrEqual(waitMs, 4_000)
        XCTAssertGreaterThan(waitMs, 3_900)
    }

    func testEveryPollOfTheBlockingAcquireCarriesAWait() async throws {
        let r = LocksAPITests.CallRecorder()
        r.script([
            .success(["acquired": false, "owner": "run-B", "retryAfterMs": 1]),
            .success(["acquired": false, "owner": "run-B", "retryAfterMs": 1]),
            .success(["acquired": true, "handle": handleJSON(handleId: "h3")]),
        ])
        let handle = try await LocksAPI(transport: r).acquire(
            key: "k", ttl: 60, timeout: 10, owner: "run-A"
        )
        XCTAssertEqual(handle.handleId, "h3")
        let sent = bodies(r)
        XCTAssertEqual(sent.count, 3)
        for body in sent {
            let waitMs = try XCTUnwrap(body["waitMs"] as? Int)
            XCTAssertGreaterThan(waitMs, 0)
            XCTAssertLessThanOrEqual(waitMs, 10_000)
            XCTAssertEqual(body["owner"] as? String, "run-A")
        }
    }

    func testAnInfiniteTimeoutAsksForTheServerCap() async throws {
        let r = LocksAPITests.CallRecorder()
        r.respond(with: ["acquired": true, "handle": handleJSON()])
        _ = try await LocksAPI(transport: r).acquire(key: "k", ttl: 60, timeout: .infinity)
        XCTAssertEqual(bodies(r).first?["waitMs"] as? Int, 30_000)
    }
}
