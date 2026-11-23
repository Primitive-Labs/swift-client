import XCTest
@testable import JsBaoClient

/// #6243 — rule sets leave buckets.
///
/// A bucket's access is one of four presets: `BlobBucketPreset` has no
/// `.custom` case, and the bucket params and `BlobBucketInfo` carry no
/// `ruleSetId`. A bucket the server stored with a rule set answers
/// `preset: "admin-only"` and `convertedFromRuleSet: true`; a response without
/// the key (an older server) decodes it as `false`.
///
/// Server-free (`*HermeticTests`): decoding and encoding are entirely
/// client-side, so the payloads are literals.
final class BlobBucketRuleSetsRetiredHermeticTests: XCTestCase {

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
          "createdBy": "u1",
          "createdAt": "2026-11-18T00:00:00.000Z",
          "modifiedAt": "2026-11-18T00:00:00.000Z"
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

    func testDecodesAConvertedBucket() throws {
        let info = try JSONDecoder().decode(
            BlobBucketInfo.self,
            from: bucketJSON(extra: "\"convertedFromRuleSet\": true,")
        )
        XCTAssertEqual(info.preset, .adminOnly)
        XCTAssertTrue(info.convertedFromRuleSet)
    }

    func testDecodesAnAbsentMarkAsFalse() throws {
        let info = try JSONDecoder().decode(BlobBucketInfo.self, from: bucketJSON())
        XCTAssertFalse(info.convertedFromRuleSet)
    }

    func testBucketInfoHasNoRuleSetIdMember() throws {
        let info = try JSONDecoder().decode(
            BlobBucketInfo.self,
            from: bucketJSON(extra: "\"convertedFromRuleSet\": false,")
        )
        XCTAssertFalse(labels(info).contains("ruleSetId"))
    }

    func testPresetHasNoCustomCase() {
        XCTAssertNil(BlobBucketPreset(rawValue: "custom"))
        XCTAssertEqual(BlobBucketPreset(rawValue: "admin-only"), .adminOnly)
    }

    func testCreateParamsCarryNoRuleSetId() throws {
        let params = CreateBlobBucketParams(
            bucketKey: "uploads",
            name: "Uploads",
            ttlTier: .permanent,
            preset: .adminOnly
        )
        XCTAssertFalse(labels(params).contains("ruleSetId"))
        XCTAssertFalse(try encodedKeys(params).contains("ruleSetId"))
    }

    func testUpdateParamsCarryNoRuleSetId() throws {
        let params = UpdateBlobBucketParams(preset: .authenticated)
        XCTAssertFalse(labels(params).contains("ruleSetId"))
        XCTAssertFalse(try encodedKeys(params).contains("ruleSetId"))
    }
}
