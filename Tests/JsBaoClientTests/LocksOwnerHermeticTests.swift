import XCTest
@testable import JsBaoClient

/// The lock owner, on the Swift client — #3562 behavior 20.
///
/// A run that takes a lock and is reset cannot get it back unless it can name
/// itself. The owner is that name, and Swift carries it rather than deferring
/// it (#3278's gap is closed one surface at a time, and this is a lock surface
/// Swift already has in full).
///
/// Two properties are the whole point of the shape below:
///
///   - **`owner` is encoded only when present.** A call that names none must
///     put the same bytes on the wire it always did (principle 5), so the
///     request body is asserted as ENCODED JSON rather than as a struct.
///   - **A body WITHOUT `owner` still decodes.** Every response field here is
///     read with `decodeIfPresent`, which is what lets a new client talk to an
///     older server and an older client to a newer one — and it is why the
///     four response types below are given bodies that predate this change.
///
/// Server-free (`*HermeticTests`): encoding and decoding are entirely
/// client-side, so the payloads are literals.
final class LocksOwnerHermeticTests: XCTestCase {

    private func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: Request encoding

    func testAcquireEncodesTheOwnerWhenOneIsNamed() throws {
        let body = try encoded(
            LockAcquireRequest(key: "jobs:import", ttlMs: 60_000, owner: "run-A")
        )
        XCTAssertEqual(body["key"] as? String, "jobs:import")
        XCTAssertEqual(body["ttlMs"] as? Int, 60_000)
        XCTAssertEqual(body["owner"] as? String, "run-A")
    }

    func testAcquireEncodesNoOwnerKeyWhenNoneIsNamed() throws {
        // The bytes a pre-#3562 caller put on the wire, unchanged: the key is
        // ABSENT rather than null.
        let body = try encoded(LockAcquireRequest(key: "jobs:import", ttlMs: 60_000))
        XCTAssertEqual(Set(body.keys), Set(["key", "ttlMs"]))
        XCTAssertNil(body["owner"])
    }

    // MARK: Response decoding

    func testAcquireResponseDecodesTheContentionOwner() throws {
        let json = """
        {
          "acquired": false,
          "heldBy": "usr_1",
          "holderKind": "user",
          "owner": "run-A",
          "leaseExpiresAt": "2026-09-18T00:00:00.000Z",
          "retryAfterMs": 250
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(LockAcquireResponse.self, from: json)
        XCTAssertFalse(response.acquired)
        XCTAssertEqual(response.owner, "run-A")
        XCTAssertEqual(response.contention?.owner, "run-A")
    }

    func testAcquireResponseDecodesABodyWithNoOwnerAtAll() throws {
        // A server that predates this change: the decode must not fail, and
        // the owner reads nil rather than throwing.
        let json = """
        {
          "acquired": false,
          "heldBy": "usr_1",
          "holderKind": "user",
          "leaseExpiresAt": "2026-09-18T00:00:00.000Z",
          "retryAfterMs": 250
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(LockAcquireResponse.self, from: json)
        XCTAssertNil(response.owner)
        XCTAssertNil(response.contention?.owner)
        XCTAssertEqual(response.contention?.retryAfterMs, 250)
    }

    func testAcquireResponseDecodesAnExplicitNullOwner() throws {
        // A hold made WITHOUT an owner: the server writes the key as null.
        let json = """
        { "acquired": false, "owner": null, "retryAfterMs": 100 }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(LockAcquireResponse.self, from: json)
        XCTAssertNil(response.owner)
    }

    func testStatusDecodesTheOwnerAndABodyWithout() throws {
        let withOwner = """
        {
          "held": true,
          "heldBy": "usr_1",
          "holderKind": "user",
          "holderRunId": "run-A",
          "owner": "run-A",
          "acquiredAt": "2026-09-18T00:00:00.000Z",
          "leaseExpiresAt": "2026-09-18T01:00:00.000Z"
        }
        """.data(using: .utf8)!
        let status = try JSONDecoder().decode(LockStatus.self, from: withOwner)
        XCTAssertEqual(status.owner, "run-A")
        XCTAssertEqual(status.holderRunId, "run-A")

        let without = """
        { "held": true, "heldBy": "usr_1", "holderKind": "user" }
        """.data(using: .utf8)!
        let older = try JSONDecoder().decode(LockStatus.self, from: without)
        XCTAssertTrue(older.held)
        XCTAssertNil(older.owner)
    }

    func testListEntryDecodesTheOwnerAndABodyWithout() throws {
        let withOwner = """
        {
          "locks": [
            {
              "key": "jobs:import",
              "heldBy": "usr_1",
              "holderKind": "user",
              "holderRunId": null,
              "owner": "run-A",
              "acquiredAt": null,
              "leaseExpiresAt": null
            }
          ]
        }
        """.data(using: .utf8)!
        let listed = try JSONDecoder().decode(LockListResult.self, from: withOwner)
        XCTAssertEqual(listed.locks.first?.owner, "run-A")

        let without = """
        { "locks": [{ "key": "jobs:import", "heldBy": "usr_1" }] }
        """.data(using: .utf8)!
        let older = try JSONDecoder().decode(LockListResult.self, from: without)
        XCTAssertNil(older.locks.first?.owner)
    }

    // MARK: Signatures

    func testTheOwnerIsATrailingDefaultOnBothAcquireSurfaces() throws {
        // A trailing default is what makes this additive: every existing call
        // site compiles unchanged. Asserted by CONSTRUCTING the calls — the
        // references below do not run, they only have to type-check.
        let withoutOwner: (LocksAPI) async throws -> LockHandle? = {
            try await $0.tryAcquire(key: "k", ttl: 60)
        }
        let withOwner: (LocksAPI) async throws -> LockHandle? = {
            try await $0.tryAcquire(key: "k", ttl: 60, owner: "run-A")
        }
        let blockingWithout: (LocksAPI) async throws -> LockHandle = {
            try await $0.acquire(key: "k", ttl: 60, timeout: 5)
        }
        let blockingWith: (LocksAPI) async throws -> LockHandle = {
            try await $0.acquire(key: "k", ttl: 60, timeout: 5, owner: "run-A")
        }
        XCTAssertNotNil(withoutOwner)
        XCTAssertNotNil(withOwner)
        XCTAssertNotNil(blockingWithout)
        XCTAssertNotNil(blockingWith)
    }
}
