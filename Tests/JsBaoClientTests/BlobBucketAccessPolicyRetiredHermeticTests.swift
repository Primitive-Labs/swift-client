import XCTest
@testable import JsBaoClient

/// #3996 — a bucket's access is `preset` (or a `ruleSetId`), and nothing else.
///
/// The pre-#1020 `accessPolicy` spelling is retired on the wire: the server
/// refuses it in a create/update body and no longer returns it. The Swift types
/// drop it in the same change, so a caller cannot build a body the server
/// refuses, and reading a bucket's access has one answer.
///
/// Server-free (`*HermeticTests`): decoding and encoding are entirely
/// client-side, so the payloads are literals.
final class BlobBucketAccessPolicyRetiredHermeticTests: XCTestCase {

    private func bucketJSON(extra: String = "") -> Data {
        """
        {
          "bucketId": "b1",
          "appId": "app1",
          "bucketKey": "uploads",
          "name": "Uploads",
          "description": null,
          "ttlTier": "permanent",
          "preset": "admin-only",
          \(extra)
          "ruleSetId": null,
          "createdBy": "u1",
          "createdAt": "2026-10-01T00:00:00.000Z",
          "modifiedAt": "2026-10-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!
    }

    private func labels(_ value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    private func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    func testBucketInfoHasNoAccessPolicyMember() throws {
        let info = try JSONDecoder().decode(BlobBucketInfo.self, from: bucketJSON())
        XCTAssertEqual(info.preset, .adminOnly)
        XCTAssertTrue(labels(info).contains("preset"))
        XCTAssertFalse(labels(info).contains("accessPolicy"))
    }

    func testStillDecodesAnOlderServerResponseThatCarriesTheAlias() throws {
        // An older server echoes `accessPolicy`; the key is simply ignored.
        let info = try JSONDecoder().decode(
            BlobBucketInfo.self,
            from: bucketJSON(extra: "\"accessPolicy\": \"owner-only\",")
        )
        XCTAssertEqual(info.preset, .adminOnly)
        XCTAssertEqual(info.bucketKey, "uploads")
    }

    func testCreateParamsCarryPresetAndNoAccessPolicy() throws {
        let params = CreateBlobBucketParams(
            bucketKey: "uploads",
            name: "Uploads",
            ttlTier: .permanent,
            preset: .adminOnly
        )
        XCTAssertFalse(labels(params).contains("accessPolicy"))
        let keys = try encodedKeys(params)
        XCTAssertTrue(keys.contains("preset"))
        XCTAssertFalse(keys.contains("accessPolicy"))
    }

    func testUpdateParamsCarryPresetAndNoAccessPolicy() throws {
        let params = UpdateBlobBucketParams(preset: .publicAccess)
        XCTAssertFalse(labels(params).contains("accessPolicy"))
        let keys = try encodedKeys(params)
        XCTAssertTrue(keys.contains("preset"))
        XCTAssertFalse(keys.contains("accessPolicy"))
    }
}
