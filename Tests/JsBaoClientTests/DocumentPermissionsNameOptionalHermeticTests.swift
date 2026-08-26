import XCTest
@testable import JsBaoClient

/// #2980 — a permission entry for a user who has no `name`.
///
/// The server serializes `name: user.name` and JSON drops the undefined key,
/// so a document shared with an OTP-provisioned user (OTP provisioning passes
/// no `name`) lists one entry WITH `name` and one WITHOUT. Swift decodes
/// strictly: while `DocumentPermissionEntry.name` was `String`, the whole
/// array decode threw `keyNotFound("name")` and `getPermissions` failed for
/// the entire document — callers using `try?` saw an empty list.
///
/// The payloads mirror the shape from the report (`primitive documents
/// permissions list --json` on alpha), with a `name` added to one entry so
/// both branches are asserted: one named permittee and one name-less one.
/// The JS side pins the same behavior against a live share in
/// `tests/client/js-bao-client-document-permissions-nameless-user.test.ts`;
/// this suite is server-free because decoding is entirely client-side, and
/// the Swift live suite cannot mint a name-less user (its `createTestUser`
/// goes through admin add-by-email, which always writes a placeholder name).
final class DocumentPermissionsNameOptionalHermeticTests: XCTestCase {

    /// One document shared by a named owner with a name-less user: the
    /// server sends `name` for the first entry and omits the key entirely
    /// for the second.
    private static let listing = """
    [
      {
        "userId": "01M0K18MVX7SSQQYV4CZNJRMA8",
        "email": "hello+primitivetest-carlchian@storybooklens.com",
        "permission": "read-write",
        "grantedAt": "2026-08-21T21:23:50.357Z"
      },
      {
        "userId": "01M0K2VJ71Y32HW3WZE3GPSDFZ",
        "email": "hello+primitivetest-chian@storybooklens.com",
        "name": "Chian",
        "permission": "owner",
        "grantedAt": "2026-08-21T21:20:43.010Z"
      }
    ]
    """

    private func makeAPI(json: String) -> DocumentsAPI {
        DocumentsAPI(
            transport: RecordingTransport(json: json),
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
    }

    /// The bug, end to end through the public call: the listing comes back
    /// whole, and each entry carries the right `name`.
    func testGetPermissionsReturnsEveryEntryWhenOneHasNoName() async throws {
        let api = makeAPI(json: Self.listing)

        let entries = try await api.getPermissions(documentId: "01M0K353TVH4ASX1AP1PDN25ZP")

        XCTAssertEqual(entries.count, 2)
        let nameless = try XCTUnwrap(entries.first { $0.userId == "01M0K18MVX7SSQQYV4CZNJRMA8" })
        let named = try XCTUnwrap(entries.first { $0.userId == "01M0K2VJ71Y32HW3WZE3GPSDFZ" })
        XCTAssertNil(nameless.name)
        XCTAssertEqual(nameless.permission, .readWrite)
        XCTAssertEqual(named.name, "Chian")
        XCTAssertEqual(named.permission, .owner)
    }

    /// A `name: null` from any serializer that writes the key explicitly is
    /// the same `nil`, not a decode failure.
    func testDecodesExplicitNullName() throws {
        let json = """
        {
          "userId": "u1",
          "email": "nameless@example.com",
          "name": null,
          "permission": "reader",
          "grantedAt": "2026-08-21T21:23:50.357Z"
        }
        """
        let entry = try JSONDecoder().decode(
            DocumentPermissionEntry.self, from: Data(json.utf8)
        )
        XCTAssertNil(entry.name)
        XCTAssertEqual(entry.email, "nameless@example.com")
    }
}
