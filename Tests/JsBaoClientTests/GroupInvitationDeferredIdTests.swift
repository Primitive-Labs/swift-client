import XCTest
@testable import JsBaoClient

/// Decode tests for `PendingGroupInvitationEntry` — issue #1465, Swift
/// parity for the `deferredId` field the server/JS client gained in #1449.
///
/// `deferredId` is the id a client passes to
/// `client.invitations.revokeDeferredGrant(deferredId, .group)` to cancel a
/// pending group invitation via `DELETE /deferred-grants/:deferredId?type=group`.
/// The JS `PendingGroupInvitationEntry` declares it as a required `string`, so
/// the Swift mirror uses a non-optional `String`.
///
/// These are pure `Decodable` checks — they don't touch the network.
final class GroupInvitationDeferredIdTests: XCTestCase {

    /// A full server payload decodes with `deferredId` populated.
    func testDecodesDeferredId() throws {
        let json = """
        {
          "email": "alice@example.com",
          "role": "member",
          "invitationId": "inv_01HZ",
          "deferredId": "dg_01HZ",
          "createdAt": "2026-07-11T00:00:00.000Z",
          "expiresAt": "2026-07-18T00:00:00.000Z",
          "addedBy": "user_owner"
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(PendingGroupInvitationEntry.self, from: json)

        XCTAssertEqual(entry.email, "alice@example.com")
        XCTAssertEqual(entry.role, "member")
        XCTAssertEqual(entry.invitationId, "inv_01HZ")
        XCTAssertEqual(entry.deferredId, "dg_01HZ")
        XCTAssertEqual(entry.createdAt, "2026-07-11T00:00:00.000Z")
        XCTAssertEqual(entry.expiresAt, "2026-07-18T00:00:00.000Z")
        XCTAssertEqual(entry.addedBy, "user_owner")
    }

    /// `addedBy` is optional and may be omitted, but `deferredId` is required
    /// and drives the value under test.
    func testDecodesWithoutOptionalAddedBy() throws {
        let json = """
        {
          "email": "bob@example.com",
          "role": "member",
          "invitationId": "inv_02HZ",
          "deferredId": "dg_02HZ",
          "createdAt": "2026-07-11T00:00:00.000Z",
          "expiresAt": "2026-07-18T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(PendingGroupInvitationEntry.self, from: json)

        XCTAssertEqual(entry.deferredId, "dg_02HZ")
        XCTAssertNil(entry.addedBy)
    }

    /// A payload missing the required `deferredId` fails to decode — this is
    /// what guards the required (non-optional) contract with the JS client.
    func testMissingDeferredIdFailsToDecode() {
        let json = """
        {
          "email": "carol@example.com",
          "role": "member",
          "invitationId": "inv_03HZ",
          "createdAt": "2026-07-11T00:00:00.000Z",
          "expiresAt": "2026-07-18T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(PendingGroupInvitationEntry.self, from: json),
            "decoding must fail when the required deferredId key is absent"
        )
    }
}
